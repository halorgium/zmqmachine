#--
#
# Author:: Chuck Remes
# Homepage::  http://github.com/chuckremes/zmqmachine
# Date:: 20100602
#
#----------------------------------------------------------------------------
#
# Copyright (C) 2010 by Chuck Remes. All Rights Reserved.
# Email: cremes at mac dot com
#
# (The MIT License)
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# 'Software'), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#---------------------------------------------------------------------------
#
#

module ZMQMachine

  class Reactor
    attr_reader :name, :context, :logger, :exception_handler

    # +name+ provides a name for this reactor instance. It's unused
    # at present but may be used in the future for allowing multiple
    # reactors to communicate amongst each other.
    #
    # +poll_interval+ is the number of milliseconds to block while
    # waiting for new 0mq socket events; default is 10
    #
    # +opts+ may contain a key +:zeromq_context+. When this
    # hash is provided, the value for :zeromq_context should be a
    # 0mq context as created by ZMQ::Context.new. The purpose of
    # providing a context to the reactor is so that multiple
    # reactors can share a single context. Doing so allows for sockets
    # within each reactor to communicate with each other via an
    # :inproc transport (:inproc is misnamed, it should be :incontext).
    # By not supplying this hash, the reactor will create and use
    # its own 0mq context.
    #
    # +opts+ may also include a +:log_transport+ key. This should be
    # a transport string for an endpoint that a logger client may connect
    # to for publishing log messages. when this key is defined, the
    # client is automatically created and connected to the indicated
    # endpoint.
    #
    # Lastly, +opts+ may include a +exception_handler+ key. The exception
    # handler should respond to #call and take a single argument.
    #
    def initialize name, poll_interval = 10, opts = {}
      @name = name
      @running = false
      @thread = nil
      @poll_interval = determine_interval poll_interval
      @timers = ZMQMachine::Timers.new

      @proc_queue = []
      @proc_queue_mutex = Mutex.new

      # could raise if it fails to allocate a Context
      @context = if opts[:zeromq_context]
        @shared_context = true
        opts[:zeromq_context]
      else
        @shared_context = false
        ZMQ::Context.new
      end

      @poller = ZMQ::Poller.new
      @sockets = []
      @raw_to_socket = {}
      Thread.abort_on_exception = true

      if opts[:log_transport]
        @logger = LogClient.new self, opts[:log_transport]
        @logging_enabled = true
      end

      if opts[:exception_handler]
        @exception_handler = opts[:exception_handler]
      end
    end

    def shared_context?
      @shared_context
    end

    # Returns true when the reactor is running OR while it is in the
    # midst of a shutdown request.
    #
    # Returns false when the reactor thread does not exist.
    #
    def running?() @running; end

    # The main entry point for all new reactor contexts. This proc
    # or block given to this method is evaluated *once* before
    # entering the reactor loop. This evaluation generally sets up
    # sockets and timers that will do the real work once the loop
    # is executed.
    #
    def run blk = nil, &block
      blk ||= block
      @running, @stopping = true, false

      @thread = Thread.new do
        blk.call self if blk

        while !@stopping && running? do
          run_once
        end

        cleanup
      end
      self
    end

    # Marks the reactor as eligible for termination. Then waits for the
    # reactor thread to exit via #join (optional timeout).
    #
    # The reactor is not forcibly terminated if it is currently blocked
    # by some long-running operation. Use #kill to forcibly terminate
    # the reactor.
    #
    def stop delay = nil
      # wait until the thread loops around again and exits on its own
      @stopping = true
      join delay
    end

    # Join on the thread running this reactor instance. Default behavior
    # is to wait indefinitely for the thread to exit.
    #
    # Pass an optional +delay+ value measured in milliseconds; the
    # thread will be stopped if it hasn't exited by the end of +delay+
    # milliseconds.
    #
    # Returns immediately when the thread has already exited.
    #
    def join delay = nil
      # don't allow the thread to try and join itself and only worry about
      # joining for live threads
      if running? && @thread.alive? && @thread != Thread.current
        if delay
          # convert to seconds to meet the argument expectations of Thread#join
          seconds = delay / 1000.0
          @thread.join seconds
        else
          @thread.join
        end
      end
    end

    # Kills the running reactor instance by terminating its thread.
    #
    # After the thread exits, the reactor attempts to clean up after itself
    # and kill any pending I/O.
    #
    def kill
      if running?
        cleanup
        @stopping = true
        @thread.kill
      end
    end

    # Schedules a proc or block to execute on the next trip through the
    # reactor loop.
    #
    # This method is thread-safe.
    #
    def next_tick blk = nil, &block
      blk ||= block
      @proc_queue_mutex.synchronize do
        @proc_queue << blk
      end
    end

    # Removes the given +sock+ socket from the reactor context. It is deregistered
    # for new events and closed. Any queued messages are silently dropped.
    #
    # Returns +true+ for a succesful close, +false+ otherwise.
    #
    def close_socket sock
      return false unless sock

      removed = delete_socket sock
      sock.raw_socket.close

      removed
    end

    # Creates a REQ socket and attaches +handler_instance+ to the
    # resulting socket. Should only be paired with one other
    # #rep_socket instance.
    #
    # +handler_instance+ must implement the #on_writable and
    # #on_writable_error methods. The reactor will call those methods
    # based upon new events.
    #
    # All handlers must implement the #on_attach method.
    #
    def req_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::Req
    end

    # Creates a REP socket and attaches +handler_instance+ to the
    # resulting socket. Should only be paired with one other
    # #req_socket instance.
    #
    # +handler_instance+ must implement the #on_readable and
    # #on_readable_error methods. The reactor will call those methods
    # based upon new events.
    #
    # All handlers must implement the #on_attach method.
    #
    def rep_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::Rep
    end

    # Creates a XREQ socket and attaches +handler_instance+ to the
    # resulting socket. Should only be paired with one other
    # #rep_socket instance.
    #
    # +handler_instance+ must implement the #on_readable,
    # #on_readable_error, #on_writable and #on_writable_error
    # methods. The reactor will call those methods
    # based upon new events.
    #
    # All handlers must implement the #on_attach method.
    #
    def xreq_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::XReq
    end

    # Creates a XREP socket and attaches +handler_instance+ to the
    # resulting socket. Should only be paired with one other
    # #req_socket instance.
    #
    # +handler_instance+ must implement the #on_readable,
    # #on_readable_error, #on_writable and #on_writable_error
    # methods. The reactor will call those methods
    # based upon new events.
    #
    # All handlers must implement the #on_attach method.
    #
    def xrep_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::XRep
    end

    # Creates a PAIR socket and attaches +handler_instance+ to the
    # resulting socket. Works only with other #pair_socket instances
    # in the same or other reactor instance.
    #
    # +handler_instance+ must implement the #on_readable and
    # #on_readable_error methods. Each handler must also implement
    # the #on_writable and #on_writable_error methods.
    # The reactor will call those methods
    # based upon new events.
    #
    # All handlers must implement the #on_attach method.
    #
    def pair_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::Pair
    end

    # Creates a PUB socket and attaches +handler_instance+ to the
    # resulting socket. Usually paired with one or more
    # #sub_socket instances in the same or other reactor instance.
    #
    # +handler_instance+ must implement the #on_writable and
    # #on_writable_error methods. The reactor will call those methods
    # based upon new events. This socket type can *only* write; it
    # can never receive/read messages.
    #
    # All handlers must implement the #on_attach method.
    #
    def pub_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::Pub
    end

    # Creates a SUB socket and attaches +handler_instance+ to the
    # resulting socket. Usually paired with one or more
    #  #pub_socket in the same or different reactor context.
    #
    # +handler_instance+ must implement the #on_readable and
    # #on_readable_error methods. The reactor will call those methods
    # based upon new events. This socket type can *only* read; it
    # can never write/send messages.
    #
    # All handlers must implement the #on_attach method.
    #
    def sub_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::Sub
    end

    # Creates a PUSH socket and attaches +handler_instance+ to the
    # resulting socket. Usually paired with one or more
    #  #pull_socket in the same or different reactor context.
    #
    # +handler_instance+ must implement the #on_writable and
    # #on_writable_error methods. The reactor will call those methods
    # based upon new events. This socket type can *only* write; it
    # can never recv messages.
    #
    # All handlers must implement the #on_attach method.
    #
    def push_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::Push
    end

    # Creates a PULL socket and attaches +handler_instance+ to the
    # resulting socket. Usually paired with one or more
    #  #push_socket in the same or different reactor context.
    #
    # +handler_instance+ must implement the #on_readable and
    # #on_readable_error methods. The reactor will call those methods
    # based upon new events. This socket type can *only* read; it
    # can never write/send messages.
    #
    # All handlers must implement the #on_attach method.
    #
    def pull_socket handler_instance
      create_socket handler_instance, ZMQMachine::Socket::Pull
    end

    # Registers the +sock+ for POLLOUT events that will cause the
    # reactor to call the handler's on_writable method.
    #
    def register_writable sock
      @poller.register_writable sock.raw_socket
    end

    # Deregisters the +sock+ for POLLOUT. The handler will no longer
    # receive calls to on_writable.
    #
    def deregister_writable sock
      @poller.deregister_writable sock.raw_socket
    end

    # Registers the +sock+ for POLLIN events that will cause the
    # reactor to call the handler's on_readable method.
    #
    def register_readable sock
      @poller.register_readable sock.raw_socket
    end

    # Deregisters the +sock+ for POLLIN events. The handler will no longer
    # receive calls to on_readable.
    #
    def deregister_readable sock
      @poller.deregister_readable sock.raw_socket
    end

    # Creates a timer that will fire a single time. Expects either a
    # +timer_proc+ proc or a block, otherwise no timer is created.
    #
    # +delay+ is measured in milliseconds (1 second equals 1000
    # milliseconds)
    #
    def oneshot_timer delay, timer_proc = nil, &blk
      blk ||= timer_proc
      @timers.add_oneshot delay, blk
    end

    # Creates a timer that will fire once at a specific
    # time as returned by ZM::Timers.now_converted.
    #
    # +exact_time+ may be either a Time object or a Numeric.
    #
    def oneshot_timer_at exact_time, timer_proc = nil, &blk
      blk ||= timer_proc
      @timers.add_oneshot_at exact_time, blk
    end

    # Creates a timer that will fire every +delay+ milliseconds until
    # it is explicitly cancelled. Expects either a +timer_proc+ proc
    # or a block, otherwise no timer is created.
    #
    # +delay+ is measured in milliseconds (1 second equals 1000
    # milliseconds)
    #
    def periodical_timer delay, timer_proc = nil, &blk
      blk ||= timer_proc
      @timers.add_periodical delay, blk
    end

    # Cancels an existing timer if it hasn't already fired.
    #
    # Returns true if cancelled, false if otherwise.
    #
    def cancel_timer timer
      @timers.cancel timer
    end

    # Asks all timers to reschedule themselves starting from Timers.now.
    # Typically called when the underlying time source for the ZM::Timers
    # class has been replaced; existing timers may not fire as expected, so
    # we ask them to reset themselves.
    #
    def reschedule_timers
      @timers.reschedule
    end

    def list_timers
      @timers.list.each do |timer|
        name = timer.respond_to?(:name) ? timer.timer_proc.name : timer.timer_proc.to_s
        puts "fire time [#{Time.at(timer.fire_time / 1000)}], method [#{name}]"
      end
    end

    def open_socket_count kind = :all
      @sockets.inject(0) do |sum, socket|
        if :all == kind || (socket.kind == kind)
          sum + 1
        else
          sum
        end
      end
    end

    # Publishes log messages to an existing transport passed in to the Reactor
    # constructor using the :log_transport key.
    #
    #  Reactor.new :log_transport => 'inproc://reactor_log'
    #
    # +level+ parameter refers to a key to indicate severity level, e.g. :warn,
    # :debug, level0, level9, etc.
    #
    # +message+ is a plain string that will be written out in its entirety.
    #
    # When no :log_transport was defined when creating the Reactor, all calls
    # just discard the messages.
    #
    #  reactor.log(:info, "some message")
    #
    # This produces output that looks like:
    #    info|20110526-10:23:47.768796 CDT|some message
    #
    def log level, message
      if @logging_enabled
        @logger.write level, message
      end
    end


    private

    def run_once
      begin
        run_procs
        run_timers
        poll
      rescue => e
        if @exception_handler
          @exception_handler.call(e)
        else
          raise
        end
      end
    end

    # Close each open socket and terminate the reactor context; this will
    # release the native memory backing each of these objects
    def cleanup
      @proc_queue_mutex.synchronize { @proc_queue.clear }

      # work on a dup since #close_socket deletes from @sockets
      @sockets.dup.each { |sock| close_socket sock }
      @context.terminate unless shared_context?
      @running = false
    end

    def run_timers
      @timers.fire_expired
    end

    # work on a copy of the queue; some procs may reschedule themselves to
    # run again immediately, so by using a copy we make them wait until the next
    # loop
    def run_procs
      work = nil
      @proc_queue_mutex.synchronize do
        work, @proc_queue = @proc_queue, []
      end

      until work.empty? do
        work.shift.call
      end
    end

    def poll
      rc = 0

      if (@proc_queue.empty? && @sockets.empty?) || @poller.size.zero?
        # when there are no sockets registered, @poller.poll would return immediately;
        # the same is true when sockets are registered but *not* for any events;
        # doing so spikes the CPU even though there is no work to do
        # take a short nap here (10ms by default) unless there are procs scheduled
        # to run (e.g. via next_tick)
        sleep(@poll_interval / 1000.0)
      else
        rc = @poller.poll @poll_interval
      end

      if ZMQ::Util.resultcode_ok?(rc)
        @poller.readables.each { |sock| @raw_to_socket[sock].resume_read }
        @poller.writables.each { |sock| @raw_to_socket[sock].resume_write }
      end

      rc
    end

    def create_socket handler_instance, kind
      sock = nil

      begin
        sock = kind.new @context, handler_instance
        save_socket sock
      rescue ZMQ::ContextError => e
        sock = nil
      end

      sock
    end

    def save_socket sock
      @poller.register sock.raw_socket, sock.poll_options
      @sockets << sock
      @raw_to_socket[sock.raw_socket] = sock
    end

    # Returns true when all steps succeed, false otherwise
    #
    def delete_socket sock
      poll_deleted = @poller.delete(sock.raw_socket)
      sockets_deleted = @sockets.delete(sock)
      ffi_deleted = @raw_to_socket.delete(sock.raw_socket)

      poll_deleted && sockets_deleted && ffi_deleted
    end


    # Unnecessary to convert the number to microseconds; the ffi-rzmq
    # library does this for us.
    #
    def determine_interval interval
      # set a lower bound of 1 millisec so we don't burn up the CPU
      interval <= 0 ? 1.0 : interval.to_i
    end

  end # class Reactor


end # module ZMQMachine
