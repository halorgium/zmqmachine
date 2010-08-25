#--
#
# Author:: Chuck Remes
# Homepage::  http://github.com/chuckremes/zmqmachine
# Date:: 20100823
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

  module Device


    # Used in conjunction with REQ/REP sockets to load balance the requests and
    # replies over (potentially) multiple backends.
    #
    # The basic mechanics are that the program contains 1 (or more) clients that
    # talk to 1 (or more) backends that all perform the same work. Connecting to
    # an intermediate queue device allows for the client requests to be fair-balanced
    # among the available backend servers. The hidden identities passed along by
    # REQ/REP sockets are used by the queue device's internal XREQ/XREP sockets to
    # route the messages back to the appropriate client.
    #
    # Example:
    #
    #  # the queue creates sockets and binds to both given addresses; all messages get
    #  # routed between the two
    #  queue = ZM::Device::Queue.new reactor, "tcp://192.168.0.100:5050", "tcp://192.168.0.100:5051"
    #
    #  # the +client_handler+ internally calls "connect" to the incoming address given above
    #  client = reactor.req_socket client_handler
    #  client2 = reactor.req_socket client_handler
    #
    #  # the +server_handler+ internally calls "connect" to the outgoing address given above
    #  server = reactor.rep_socket server_handler
    #
    class Queue

      class Handler
        attr_accessor :socket_out

        def initialize reactor, address, debug = false, dir = 0
          @reactor = reactor
          @address = address
          @debug = debug
          @dir = dir
        end

        def on_attach socket
          socket.identity = "queue.#{Kernel.rand(999_999_999)}"
          rc = socket.bind @address
          #FIXME: error handling!
        end

        def on_writable socket
          @reactor.deregister_writable socket
        end

        def on_readable socket, messages
          messages.each { |msg| puts "[#{@dir}] [#{msg.copy_out_string}]" } if @debug

          if @socket_out
            socket_out.send_messages messages
          end
        end
      end # class Handler


      # Takes either a properly formatted string that can be converted into a ZM::Address
      # or takes a ZM::Address directly.
      #
      # Routes all messages received by either address to the other address.
      #
      def initialize reactor, incoming, outgoing, debug = false
        incoming = Address.from_string incoming if incoming.kind_of? String
        outgoing = Address.from_string outgoing if outgoing.kind_of? String

        # setup the handlers for processing messages
        @handler_in = Handler.new reactor, incoming, debug, :in
        @handler_out = Handler.new reactor, outgoing, debug, :out

        # create each socket and pass in the appropriate handler
        @incoming = reactor.xrep_socket @handler_in
        @outgoing = reactor.xreq_socket @handler_out

        # set each handler's outgoing socket
        @handler_in.socket_out = @outgoing
        @handler_out.socket_out = @incoming
      end
    end # class Queue

  end # module Device

end # module ZMQMachine
