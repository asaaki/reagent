#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#                    Version 2, December 2004
#
#            DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
#   TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
#
#  0. You just DO WHAT THE FUCK YOU WANT TO.

defmodule Reagent.Listener do
  alias Data.Set
  alias Data.Dict
  alias Data.Queue

  @opaque t :: record

  defrecordp :listener, __MODULE__, socket: nil, id: nil, module: nil, port: nil, secure: nil, options: [],
    env: nil, acceptors: nil, connections: nil, waiting: nil

  @doc """
  Get the id of the listener.
  """
  @spec id(t) :: pid
  def id(listener(id: id)) do
    id
  end

  @spec env(pid | t) :: term
  def env(id) when id |> is_pid do
    :gen_server.call(id, :env) |> Dict.get(id)
  end

  def env(listener(id: id, env: table)) do
    table |> Dict.get(id)
  end

  @spec env(pid | t, reference) :: term
  def env(id, conn) when id |> is_pid do
    :gen_server.call(id, :env) |> Dict.get(conn)
  end

  def env(listener(env: table), id) do
    table |> Dict.get(id)
  end

  @doc """
  Check if the connection is secure or not.
  """
  @spec secure?(t) :: boolean
  def secure?(listener(secure: nil)), do: false
  def secure?(listener()),            do: true

  @doc """
  Get the certificate of the listener.
  """
  @spec cert(t) :: String.t
  def cert(listener(secure: nil)), do: nil
  def cert(listener(secure: sec)), do: sec[:cert]

  @spec socket(t) :: Socket.t
  def socket(listener(socket: socket)) do
    socket
  end

  def start(descriptor) do
    :gen_server.start __MODULE__, descriptor, []
  end

  def start_link(descriptor) do
    :gen_server.start_link __MODULE__, descriptor, []
  end

  def init(descriptor) do
    if descriptor[:profile] do
      Reagent.Profile.start
    end

    id        = Process.self
    module    = Keyword.fetch! descriptor, :module
    port      = Keyword.fetch! descriptor, :port
    secure    = Keyword.get descriptor, :secure
    acceptors = Keyword.get descriptor, :acceptors, 100
    options   = Keyword.get descriptor, :options, []

    socket = if secure do
      Socket.SSL.listen port, to_options(options, secure)
    else
      Socket.TCP.listen port, to_options(options)
    end

    case socket do
      { :ok, socket } ->
        Process.flag :trap_exit, true

        table = Exts.Table.new(automatic: false, access: :public)
        table |> Dict.put(id, descriptor[:env])

        listener = listener(
          socket:      socket,
          id:          id,
          module:      module,
          port:        port,
          secure:      secure,
          options:     options,
          env:         table,
          acceptors:   HashSet.new,
          connections: HashDict.new,
          waiting:     Queue.Simple.new)

        :gen_server.cast Process.self, { :acceptors, acceptors }

        { :ok, listener }

      { :error, reason } ->
        { :stop, reason }
    end
  end

  defp to_options(options) do
    options |> Keyword.merge(mode: :passive, automatic: false)
  end

  defp to_options(options, secure) do
    options |> Keyword.merge(secure) |> Keyword.merge(mode: :passive, automatic: false)
  end

  def terminate(_, listener(socket: socket)) do
    socket |> Socket.close
  end

  def handle_call(:env, _from, listener(env: env) = listener) do
    { :reply, env, listener }
  end

  def handle_call(:wait, from, listener(options: options, connections: connections, waiting: waiting) = listener) do
    case Keyword.fetch(options, :max_connections) do
      :error ->
        { :reply, :ok, listener }

      { :ok, max } ->
        if Data.count(connections) >= max do
          { :noreply, listener(listener, waiting: Queue.enq(waiting, from)) }
        else
          { :reply, :ok, listener }
        end
    end
  end

  def handle_cast({ :acceptors, number }, listener(acceptors: acceptors) = listener) when number > 0 do
    pids = Enum.map 1 .. number, fn _ ->
      Process.spawn_link __MODULE__, :acceptor, [listener]
    end

    { :noreply, listener(listener, acceptors: Set.union(acceptors, HashSet.new(pids))) }
  end

  def handle_cast({ :acceptors, number }, listener(acceptors: acceptors) = listener) when number < 0 do
    { keep, drop } = Enum.split(acceptors, -number)

    Enum.each drop, fn pid ->
      Process.exit pid, :drop
    end

    { :noreply, listener(listener, acceptors: HashSet.new(keep)) }
  end

  def handle_cast({ :accepted, pid, conn }, listener(connections: connections) = listener) do
    { :noreply, listener(listener, connections: Dict.put(connections, Process.monitor(pid), conn)) }
  end

  def handle_info({ :EXIT, pid, reason }, listener(acceptors: acceptors) = listener) do
    acceptors = Set.delete(acceptors, pid) |> Set.add(Process.spawn_link(__MODULE__, :acceptor, [listener]))
    listener  = listener(listener, acceptors: acceptors)

    { :noreply, listener }
  end

  def handle_info({ :DOWN, ref, _type, _object, _info }, listener(connections: connections, waiting: waiting, env: table) = listener) do
    connection  = Dict.get(connections, ref)
    connections = Dict.delete(connections, ref)

    Dict.delete(table, connection.id)

    case Queue.deq(waiting) do
      { nil, _ } ->
        { :noreply, listener(listener, connections: connections) }

      { from, rest } ->
        :gen_server.reply(from, :ok)

        { :noreply, listener(listener, connections: connections, waiting: rest) }
    end
  end

  @doc false
  def acceptor(listener(id: id, module: module) = listener) do
    wait(listener)

    case module.accept(listener) do
      { :ok, socket } ->
        conn = Reagent.Connection.new(listener: listener, socket: socket)

        case module.start(conn) do
          :ok ->
            module.handle(conn)

          { :ok, pid } ->
            socket |> Socket.process!(pid)
            pid <- { Reagent, :ack }

            :gen_server.cast id, { :accepted, pid, conn }

            acceptor(listener)

          { :error, reason } ->
            exit reason
        end

      { :error, reason } ->
        exit reason
    end
  end

  defp wait(listener(id: id)) do
    :gen_server.call id, :wait
  end
end
