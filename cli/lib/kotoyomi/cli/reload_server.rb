# frozen_string_literal: true

require "socket"

class Kotoyomi::CLI
  # SSE server for live reload
  class ReloadServer
    HEADERS = "HTTP/1.1 200 OK\r\n" \
              "Content-Type: text/event-stream\r\n" \
              "Cache-Control: no-cache\r\n" \
              "Connection: keep-alive\r\n" \
              "Access-Control-Allow-Origin: *\r\n\r\n"

    def initialize(port, host: "127.0.0.1")
      @port = port
      @host = host
      @clients = []
      @mutex = Mutex.new
    end

    # Returns nil on failure (e.g. port in use) so the caller can treat live
    # reload as a best-effort feature and serve without it.
    def start
      @server = TCPServer.new(@host, @port)
      @accept = Thread.new { accept_loop }
      self
    rescue StandardError
      nil
    end

    # A failed write means the client is gone; drop it so the list doesn't grow
    # unbounded across rebuilds.
    def notify
      @mutex.synchronize do
        @clients.reject! do |sock|
          sock.write("event: reload\ndata: 1\n\n")
          sock.flush
          false
        rescue StandardError
          close(sock)
          true
        end
      end
    end

    def stop
      @server&.close
      @accept&.kill
      @mutex.synchronize do
        @clients.each { |s| close(s) }
        @clients.clear
      end
    rescue StandardError
      nil
    end

    private

    def accept_loop
      loop { Thread.new(@server.accept) { |s| handle(s) } }
    rescue StandardError
      nil # the server was closed
    end

    def handle(sock)
      # Must drain the request before replying, even though we ignore it.
      while (line = sock.gets) && line != "\r\n"; end

      sock.write(HEADERS)
      sock.write(": connected\n\n") # so the browser fires EventSource#onopen
      sock.flush
      @mutex.synchronize { @clients << sock }

      # Hold the socket open for the life of the SSE stream; #notify writes to it.
      sock.read
    rescue StandardError
      nil
    ensure
      @mutex.synchronize { @clients.delete(sock) }
      close(sock)
    end

    def close(sock)
      sock.close
    rescue StandardError
      nil
    end
  end
end
