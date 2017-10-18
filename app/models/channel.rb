# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/

class Channel < ApplicationModel
  load 'channel/assets.rb'
  include Channel::Assets

  belongs_to :group,  class_name: 'Group'

  store :options
  store :preferences

  after_create   :email_address_check
  after_update   :email_address_check
  after_destroy  :email_address_check

  # rubocop:disable Style/ClassVars
  @@channel_stream = {}
  @@channel_stream_started_till_at = {}
# rubocop:enable Style/ClassVars

=begin

fetch all accounts

  Channel.fetch

=end

  def self.fetch
    channels = Channel.where('active = ? AND area LIKE ?', true, '%::Account')
    channels.each(&:fetch)
  end

=begin

fetch one account

  channel = Channel.where(area: 'Email::Account').first
  channel.fetch

=end

  def fetch(force = false)

    adapter         = options[:adapter]
    adapter_options = options
    if options[:inbound] && options[:inbound][:adapter]
      adapter         = options[:inbound][:adapter]
      adapter_options = options[:inbound][:options]
    end

    begin

      # we need to require each channel backend individually otherwise we get a
      # 'warning: toplevel constant Twitter referenced by Channel::Driver::Twitter' error e.g.
      # so we have to convert the channel name to the filename via Rails String.underscore
      # http://stem.ps/rails/2015/01/25/ruby-gotcha-toplevel-constant-referenced-by.html
      require "channel/driver/#{adapter.to_filename}"

      driver_class    = Object.const_get("Channel::Driver::#{adapter.to_classname}")
      driver_instance = driver_class.new
      return if !force && !driver_instance.fetchable?(self)
      result = driver_instance.fetch(adapter_options, self)
      self.status_in   = result[:result]
      self.last_log_in = result[:notice]
      preferences[:last_fetch] = Time.zone.now
      save!
    rescue => e
      error = "Can't use Channel::Driver::#{adapter.to_classname}: #{e.inspect}"
      logger.error error
      logger.error e.backtrace
      self.status_in = 'error'
      self.last_log_in = error
      preferences[:last_fetch] = Time.zone.now
      save!
    end

  end

=begin

stream instance of account

  channel = Channel.where(area: 'Twitter::Account').first
  stream_instance = channel.stream_instance

  # start stream
  stream_instance.stream

=end

  def stream_instance

    adapter = options[:adapter]

    begin

      # we need to require each channel backend individually otherwise we get a
      # 'warning: toplevel constant Twitter referenced by Channel::Driver::Twitter' error e.g.
      # so we have to convert the channel name to the filename via Rails String.underscore
      # http://stem.ps/rails/2015/01/25/ruby-gotcha-toplevel-constant-referenced-by.html
      require "channel/driver/#{adapter.to_filename}"

      driver_class    = Object.const_get("Channel::Driver::#{adapter.to_classname}")
      driver_instance = driver_class.new

      # check is stream exists
      return if !driver_instance.respond_to?(:stream_instance)
      driver_instance.stream_instance(self)

      # set scheduler job to active

      return driver_instance
    rescue => e
      error = "Can't use Channel::Driver::#{adapter.to_classname}: #{e.inspect}"
      logger.error error
      logger.error e.backtrace
      self.status_in = 'error'
      self.last_log_in = error
      save!
    end

  end

=begin

stream all accounts

  Channel.stream

=end

  def self.stream
    Thread.abort_on_exception = true

    auto_reconnect_after = 180
    delay_before_reconnect = 70
    last_channels = []

    loop do
      logger.debug 'stream controll loop'

      current_channels = []
      channels = Channel.where('active = ? AND area LIKE ?', true, '%::Account')
      channels.each do |channel|
        adapter = channel.options[:adapter]
        next if adapter.blank?
        driver_class = Object.const_get("Channel::Driver::#{adapter.to_classname}")
        next if !driver_class.respond_to?(:streamable?)
        next if !driver_class.streamable?
        channel_id = channel.id.to_s

        current_channels.push channel_id

        # exit it channel has changed or connection is older then 180 minutes
        if @@channel_stream[channel_id].present?
          if @@channel_stream[channel_id][:options] != channel.options
            logger.info "channel options (#{channel.id}) has changed, stop stream thread"
            @@channel_stream[channel_id][:thread].exit
            @@channel_stream[channel_id][:thread].join
            @@channel_stream[channel_id][:stream_instance].disconnect
            @@channel_stream.delete(channel_id)
            @@channel_stream_started_till_at[channel_id] = Time.zone.now
            next
          elsif @@channel_stream[channel_id][:started_at] && @@channel_stream[channel_id][:started_at] < Time.zone.now - auto_reconnect_after.minutes
            logger.info "channel (#{channel.id}) reconnect - stream thread is older then #{auto_reconnect_after} minutes, restart thread"
            @@channel_stream[channel_id][:thread].exit
            @@channel_stream[channel_id][:thread].join
            @@channel_stream[channel_id][:stream_instance].disconnect
            @@channel_stream.delete(channel_id)
            @@channel_stream_started_till_at[channel_id] = Time.zone.now
            next
          end
        end

        local_delay_before_reconnect = delay_before_reconnect
        if channel.status_in == 'error'
          local_delay_before_reconnect = local_delay_before_reconnect * 2
        end
        if @@channel_stream[channel_id].blank? && @@channel_stream_started_till_at[channel_id].present?
          wait_in_seconds = @@channel_stream_started_till_at[channel_id] - (Time.zone.now - local_delay_before_reconnect.seconds)
          if wait_in_seconds.positive?
            logger.info "skipp channel (#{channel_id}) for streaming, already tried to connect or connection was active within the last #{local_delay_before_reconnect} seconds - wait another #{wait_in_seconds} seconds"
            next
          end
        end

        #logger.info "thread stream for channel (#{channel.id}) already running" if @@channel_stream[channel_id].present?
        next if @@channel_stream[channel_id].present?

        @@channel_stream[channel_id] = {
          options: channel.options,
          started_at: Time.zone.now,
        }

        # start channels with delay
        sleep @@channel_stream.count

        # start threads for each channel
        @@channel_stream[channel_id][:thread] = Thread.new do
          begin
            logger.info "Started stream channel for '#{channel.id}' (#{channel.area})..."
            channel.status_in = 'ok'
            channel.last_log_in = ''
            channel.save!
            @@channel_stream_started_till_at[channel_id] = Time.zone.now
            @@channel_stream[channel_id] ||= {}
            @@channel_stream[channel_id][:stream_instance] = channel.stream_instance
            @@channel_stream[channel_id][:stream_instance].stream
            @@channel_stream[channel_id][:stream_instance].disconnect
            @@channel_stream.delete(channel_id)
            @@channel_stream_started_till_at[channel_id] = Time.zone.now
            logger.info " ...stopped stream thread for '#{channel.id}'"
          rescue => e
            error = "Can't use stream for channel (#{channel.id}): #{e.inspect}"
            logger.error error
            logger.error e.backtrace
            channel.status_in = 'error'
            channel.last_log_in = error
            channel.save!
            @@channel_stream.delete(channel_id)
            @@channel_stream_started_till_at[channel_id] = Time.zone.now
          end
        end
      end

      # cleanup deleted channels
      last_channels.each do |channel_id|
        next if @@channel_stream[channel_id].blank?
        next if current_channels.include?(channel_id)
        logger.info "channel (#{channel_id}) not longer active, stop stream thread"
        @@channel_stream[channel_id][:thread].exit
        @@channel_stream[channel_id][:thread].join
        @@channel_stream[channel_id][:stream_instance].disconnect
        @@channel_stream.delete(channel_id)
        @@channel_stream_started_till_at[channel_id] = Time.zone.now
      end

      last_channels = current_channels

      sleep 20
    end

  end

=begin

send via account

  channel = Channel.where(area: 'Email::Account').first
  channel.deliver(mail_params, notification)

=end

  def deliver(mail_params, notification = false)

    adapter         = options[:adapter]
    adapter_options = options
    if options[:outbound] && options[:outbound][:adapter]
      adapter         = options[:outbound][:adapter]
      adapter_options = options[:outbound][:options]
    end

    result = nil

    begin

      # we need to require each channel backend individually otherwise we get a
      # 'warning: toplevel constant Twitter referenced by Channel::Driver::Twitter' error e.g.
      # so we have to convert the channel name to the filename via Rails String.underscore
      # http://stem.ps/rails/2015/01/25/ruby-gotcha-toplevel-constant-referenced-by.html
      require "channel/driver/#{adapter.to_filename}"

      driver_class    = Object.const_get("Channel::Driver::#{adapter.to_classname}")
      driver_instance = driver_class.new
      result = driver_instance.send(adapter_options, mail_params, notification)
      self.status_out   = 'ok'
      self.last_log_out = ''
      save!
    rescue => e
      error = "Can't use Channel::Driver::#{adapter.to_classname}: #{e.inspect}"
      logger.error error
      logger.error e.backtrace
      self.status_out = 'error'
      self.last_log_out = error
      save!
      raise error
    end
    result
  end

  private

  def email_address_check

    # reset non existing channel_ids
    EmailAddress.channel_cleanup
  end

end
