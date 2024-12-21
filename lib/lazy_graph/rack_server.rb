# frozen_string_literal: true

require 'socket'

module LazyGraph
  class RackServer
    def initialize(app)
      @app       = app
      @running   = false
      @threads   = [] #
      @threads_m = Mutex.new
    end

    def start(port: 9292, workers: 4)
      trap_signals

      @port = port
      @workers = workers

      if workers > 1
        puts "Starting Raxx server with #{workers} processes on port #{port}..."
        @server = TCPServer.new(@port)
        @server.listen(1024)

        workers.times do
          fork(&method(:run_accept_loop))
        end
        Process.waitall
      else
        puts "Starting single-process server on port #{port}..."
        @server = TCPServer.new(@port)
        @server.listen(1024)
        run_accept_loop
      end
    end

    private

    #
    # Main accept loop
    #
    def run_accept_loop
      enable_reuse(@server)
      @running = true
      puts "[PID #{Process.pid}] Listening on port #{@port}..."

      while @running
        begin
          client = @server.accept_nonblock if @running
        rescue IO::WaitReadable, Errno::EINTR
          IO.select([@server], nil, nil, 0.1) if @running
          retry
        end

        # Handle connection in a new thread
        next unless client

        thr = Thread.start(client) do |socket|
          socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
          handle_request(socket)
          socket.close
        rescue Errno::ECONNRESET, Errno::EPIPE, IOError, Errno::EINVAL
          # Connection reset by peer - ignore
        ensure
          remove_thread(Thread.current)
        end

        add_thread(thr)
      end
    ensure
      if @server
        puts "[PID #{Process.pid}] Shutting down server socket..."
        @server.close
      end
    end

    #
    # Actually handle requests in a keep-alive loop
    #
    def handle_request(socket)
      while @running

        begin
          request_line = socket.gets if @running
        rescue IO::WaitReadable, Errno::EINTR, Errno::EPIPE
          IO.select([socket], nil, nil, 0.5) if @running
          retry
        end

        break if request_line.nil? || request_line.strip.empty?

        method, path, http_version = request_line.split

        # Parse headers
        headers = {}
        content_length = 0
        while (line = socket.gets) && line != "\r\n"
          key, value = line.split(': ', 2)
          headers[key.downcase] = value.strip
          content_length = value.to_i if key == 'Content-Length'
        end

        body = content_length.positive? ? socket.read(content_length) : (+'').force_encoding('ASCII-8BIT')

        # Build Rack environment
        env = {
          'REQUEST_METHOD' => method,
          'PATH_INFO' => path,
          'HTTP_VERSION' => http_version,
          'QUERY_STRING' => path[/\?.*/].to_s,
          'SERVER_PROTOCOL' => 'HTTP/1.1',
          'SERVER_NAME' => 'localhost',
          'rack.url_scheme' => 'http',
          'rack.request.headers' => headers,
          'rack.input' => StringIO.new(body),
          'rack.errors' => StringIO.new('')
        }

        # Call the Rack app
        status, response_headers, body_enum = @app.call(env)

        content = body_enum.to_enum(:each).map(&:to_s).join

        response_headers['Connection'] = 'keep-alive'
        response_headers['Content-Length'] = content.bytesize.to_s

        # Write the response
        socket.print "HTTP/1.1 #{status} #{http_status_message(status)}\r\n"
        response_headers.each { |k, v| socket.print "#{k}: #{v}\r\n" }
        socket.print "\r\n"
        socket.print content
      end
    end

    #
    # Thread management helpers
    #
    def add_thread(thr)
      @threads_m.synchronize { @threads << thr }
    end

    def remove_thread(thr)
      @threads_m.synchronize { @threads.delete(thr) }
    end

    #
    # Trap signals, set @running = false, then force-kill leftover threads
    #
    def trap_signals
      %w[INT TERM].each do |signal|
        trap(signal) do
          @running = false
          # Give threads a grace period to finish
          graceful_shutdown_threads(timeout: 5)
        end
      end
    end

    #
    # Gracefully wait for each thread to finish; then force-kill if still alive
    #
    def graceful_shutdown_threads(timeout:)
      @threads.each do |thr|
        next unless thr.alive?

        # Try a graceful join
        thr.join(timeout)
        # If still running after timeout, forcibly kill
        if thr.alive?
          puts "[PID #{Process.pid}] Force-killing thread #{thr.object_id}"
          thr.kill
        end
      end
    end

    #
    # Reuse port if supported
    #
    def enable_reuse(server)
      server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      begin
        server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, true)
      rescue StandardError
        # Not supported on all systems
        nil
      end
    end

    #
    # Utility: Convert a status code to reason phrase
    #
    def http_status_message(status)
      {
        200 => 'OK',
        404 => 'Not Found'
      }[status] || 'Unknown'
    end
  end
end
