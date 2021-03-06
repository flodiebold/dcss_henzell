#! /usr/bin/env ruby

require 'gserver'
require 'helper'

module TV
  @@tv_args = nil
  @channel_server = !!ENV['TV_CHANNEL_SERVER']

  TV_QUEUE_FILE = 'tv.queue'
  TV_LOCK_FILE = 'tv.queue.lock'
  DIRSERV_LOCK_FILE = 'dirserv.queue.lock'
  TV_LOG_FILE = 'tv.queue.log'
  DIRSERV_LOG_FILE = 'dirserv.queue.log'

  def self.channel_server?
    @channel_server
  end

  def self.as_channel_server
    old_channel_server = @channel_server
    old_env = ENV['TV_CHANNEL_SERVER']
    begin
      @channel_server = true
      ENV['TV_CHANNEL_SERVER'] = 'y'
      yield
    ensure
      @channel_server = old_channel_server
      ENV['TV_CHANNEL_SERVER'] = old_env
    end
  end

  # Serves ttyrec directory listings to whoever asks.
  class TtyrecDirectoryServ < GServer
    def initialize(port = 21977, host = "0.0.0.0")
      puts "Starting ttyrec listing server."
      super(port, host, Float::MAX, $stderr, true)
    end

    def serve(sock)
      while true
        nick = sock.gets.chomp
        puts "ttyrec listing requested for '#{nick}'"
        last unless nick
        list_ttyrecs(nick, sock)
      end
    end

    def list_ttyrecs(nick, sock)
      if nick =~ /^[a-z0-9_ -]+$/i
        for ttyrec in Dir[DGL_TTYREC_DIR + "/#{nick}/*.ttyrec*"]
          if ttyrec =~ %r{.*/(.*)}
            sock.write("#$1 #{File.size(ttyrec)} ")
          end
        end
      end
      sock.write("\r\n")
    end
  end

  # Serves TV requests to FooTV instances.
  class TVServ < GServer
    def initialize(port = 21976, host = "0.0.0.0")
      puts "Starting TV notification server."
      @started = Time.now.strftime("%s").to_i
      @clients = []
      @mutex = Mutex.new
      @monitor = nil
      super(port, host, Float::MAX, $stderr, true)
    end

    def bootstrap_client
      queue = []
      class << queue
        def mutex
          @tmutex ||= Mutex.new
        end
      end

      # Create the mutex now.
      queue.mutex

      @mutex.synchronize do
        @clients << queue
        unless @monitor
          @monitor = Thread.new { run_monitor }
        end
      end
      queue
    end

    def run_monitor
      begin
        while true
          open(TV_QUEUE_FILE, 'r+') do |af|
            TV.flock(af, File::LOCK_EX) do |f|
              lines = f.readlines
              f.truncate(0)

              new_lines = lines.find_all do |line|
                if line =~ /^(\d+) .*/
                  start = $1.to_i
                  start >= @started
                end
              end

              clients = @mutex.synchronize { @clients }
              clients.each do |c|
                c.mutex.synchronize do
                  c.push(*new_lines)
                end
              end
            end
          end
          sleep 3
        end
      rescue
        puts "Monitor: #$!"
      end
    end

    def serve(sock)
      queue = nil
      begin
        queue = bootstrap_client()
        while true
          queue.mutex.synchronize do
            queue.each do |q|
              sock.write(q)
              sock.flush
            end
            queue.clear
          end
          sleep 3
        end
      rescue
        puts "Ack: #$!"
      ensure
        if queue
          @mutex.synchronize do
            @clients.delete_if { |q| q.object_id == queue.object_id }
          end
        end
      end
    end
  end

  def self.flock(file, mode)
    success = file.flock(mode)
    if success
      begin
        res = yield file
        return res
      ensure
        file.flock(File::LOCK_UN)
      end
    end
    nil
  end

  def self.oflock(filename, mode)
    open(filename, 'w') do |of|
      flock(of, mode) do |f|
        return yield(f)
      end
    end
    nil
  end

  def self.launch_dirserv()
    return unless File.exist?(DGL_TTYREC_DIR)
    return if fork()

    begin
      Process.setsid
    ensure
    end

    # Try for a lock, but do not block
    oflock(DIRSERV_LOCK_FILE, File::LOCK_EX | File::LOCK_NB) do |f|
      # Be a good citizen:
      logfile = File.open(DIRSERV_LOG_FILE, 'w')
      logfile.sync = true
      STDOUT.reopen(logfile)
      STDERR.reopen(logfile)
      STDIN.close()

      # Start the ttyrec listing server.
      ttyrec_lister = TtyrecDirectoryServ.new
      ttyrec_lister.start()
      ttyrec_lister.join()
    end
    exit 0
  end

  def self.launch_daemon()
    return if fork()

    begin
      Process.setsid
    ensure
    end

    # Try for a lock, but do not block
    oflock(TV_LOCK_FILE, File::LOCK_EX | File::LOCK_NB) do |f|

      # Be a good citizen:
      logfile = File.open(TV_LOG_FILE, 'w')
      logfile.sync = true
      STDOUT.reopen(logfile)
      STDERR.reopen(logfile)
      STDIN.close()

      # Start the notification server and wait on it.
      tv = TVServ.new
      tv.start()
      tv.join()
    end
    exit 0
  end

  def self.parse_tv_args(opts)
    hash = { }
    for key in opts.keys
      if key == :cancel || key == :nuke
        self.parse_tv_arg(hash, key.to_s)
      elsif key == :tv
        value = opts[key]
        next unless value.is_a?(String)
        value.split(':').each { |v| self.parse_tv_arg(hash, v) }
      end
    end
    hash
  end

  def self.parse_seek_num(seek, num, allow_end=false)
    seekname = seek == '<' ? 'seek-back' : 'seek-after'
    expected = allow_end ? 'T<turncount>, number or "$"' : 'T<turncount> or number'
    if (num !~ /^t[+-]?\d+$/i && num !~ /^[-+]?\d+(?:\.\d+)?$/ &&
        (!allow_end || num != '$'))
      raise "Bad seek argument for #{seekname}: #{num} (#{expected} expected)"
    end
    num
  end

  def self.read_playback_speed(speed_string)
    speed = speed_string.to_f
    if speed < 0.1 || speed > 10
      raise "Playback speed must be between 0.1 and 10"
    end
    speed
  end

  def self.parse_tv_arg(hash, key)
    if key == 'cancel' or key == 'nuke'
      hash[key] = 'y'
    else
      prefix = key[0..0].downcase
      rest = key[1 .. -1].strip
      case prefix
      when '<'
        hash['seekbefore'] = parse_seek_num(prefix, rest)
      when '>'
        hash['seekafter'] = parse_seek_num(prefix, rest, true)
      when 't'
        hash['seekafter'] = parse_seek_num('<', prefix + rest)
      when 'x'
        hash['playback_speed'] = read_playback_speed(rest)
      else
        raise "Unrecognised TV option: #{key}"
      end
    end
  end

  def self.with_tv_opts(argv, tv_command = false)
    opts = %w/tv/
    opts += %w/cancel nuke/ if tv_command

    args, opts = extract_options(argv, *opts)
    old_args = @@tv_args
    begin
      @@tv_args = parse_tv_args(opts)
      yield args, opts
    rescue
      puts $!
      raise
    ensure
      @@tv_args = old_args
    end
  end

  def self.request_game(g)
    # Launch a daemon that keeps a server socket open for interested
    # parties (i.e. C-SPLAT) to listen in.
    launch_daemon()

    open(TV_QUEUE_FILE, 'a') do |file|
      flock(file, File::LOCK_EX) do |f|
        # Make sure we're really at eof.
        f.seek(0, IO::SEEK_END)
        stripped = g
        f.puts "#{Time.now.strftime('%s')} #{munge_game(stripped)}"
      end
    end
  end

  def self.request_game_verbosely(n, g, who)
    summary = short_game_summary(g)
    tv = 'FooTV'

    unless TV.channel_server?
      if @@tv_args && @@tv_args['nuke']
        puts "FooTV playlist clear requested by #{who}."
      else
        suffix = @@tv_args && @@tv_args['cancel'] ? ' cancel' : ''
        puts "#{n}. #{summary}#{suffix} requested for #{tv}."
      end

      update_tv_count(g)
      g['req'] = ARGV[1]
    end

    if @@tv_args
      for k in @@tv_args.keys
        g[k] = @@tv_args[k]
      end
    end

    if TV.channel_server?
      puts "#{n}. :#{munge_game(g)}:"
      return
    else
      request_game(g)
    end
  end
end
