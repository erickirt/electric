defmodule Support.ComponentSetup do
  import ExUnit.Callbacks
  import ExUnit.Assertions
  import Support.TestUtils, only: [full_test_name: 1]

  alias Electric.ShapeCache.Storage
  alias Electric.Replication.ShapeLogCollector
  alias Electric.ShapeCache
  alias Electric.ShapeCache.PureFileStorage
  alias Electric.ShapeCache.InMemoryStorage
  alias Electric.Postgres.Inspector.EtsInspector

  defmodule NoopPublicationManager do
    @behaviour Electric.Replication.PublicationManager
    def name(_), do: :pub_man
    def add_shape(_handle, _shape, _opts), do: :ok
    def recover_shape(_handle, _shape, _opts), do: :ok
    def remove_shape(_handle, _shape, _opts), do: :ok
    def refresh_publication(_opts), do: :ok
  end

  defmodule TestPublicationManager do
    @behaviour Electric.Replication.PublicationManager

    def new do
      {__MODULE__, %{parent: self()}}
    end

    def name(_), do: TestPublicationManager

    def add_shape(handle, shape, %{parent: parent}) do
      send(parent, {TestPublicationManager, :add_shape, handle, shape})
      :ok
    end

    def recover_shape(handle, shape, %{parent: parent}) do
      send(parent, {TestPublicationManager, :recover_shape, handle, shape})
      :ok
    end

    def remove_shape(handle, shape, %{parent: parent}) do
      send(parent, {TestPublicationManager, :remove_shape, handle, shape})
      :ok
    end

    def refresh_publication(%{parent: parent}) do
      send(parent, {TestPublicationManager, :refresh_publication})
      :ok
    end
  end

  def with_stack_id_from_test(ctx) do
    stack_id = full_test_name(ctx)
    registry = start_link_supervised!({Electric.ProcessRegistry, stack_id: stack_id})
    %{stack_id: stack_id, process_registry: registry}
  end

  def with_registry(ctx) do
    registry_name = :"#{inspect(Registry.ShapeChanges)}:#{ctx.stack_id}"
    start_link_supervised!({Registry, keys: :duplicate, name: registry_name})

    %{registry: registry_name}
  end

  def with_in_memory_storage(ctx) do
    storage_opts =
      InMemoryStorage.shared_opts(
        table_base_name: :"in_memory_storage_#{ctx.stack_id}",
        stack_id: ctx.stack_id
      )

    %{storage: {InMemoryStorage, storage_opts}}
  end

  def with_tracing_storage(%{storage: storage}) do
    [storage: Support.TestStorage.wrap(storage, %{})]
  end

  def with_no_pool(_ctx) do
    %{pool: :no_pool}
  end

  def with_pure_file_storage(ctx) do
    storage =
      Storage.shared_opts({PureFileStorage, storage_dir: ctx.tmp_dir, stack_id: ctx.stack_id})

    start_supervised!(Storage.stack_child_spec(storage), restart: :temporary)

    %{storage: storage}
  end

  def with_persistent_kv(_ctx) do
    kv = Electric.PersistentKV.Memory.new!()
    %{persistent_kv: kv}
  end

  def with_log_chunking(_ctx) do
    %{chunk_bytes_threshold: Electric.ShapeCache.LogChunker.default_chunk_size_threshold()}
  end

  def with_publication_manager(ctx) do
    server = :"publication_manager_#{full_test_name(ctx)}"

    start_link_supervised!(%{
      id: server,
      start: {
        Electric.Replication.PublicationManager,
        :start_link,
        [
          [
            name: server,
            stack_id: ctx.stack_id,
            publication_name: ctx.publication_name,
            update_debounce_timeout: Access.get(ctx, :update_debounce_timeout, 0),
            db_pool: ctx.pool,
            pg_version: Access.get(ctx, :pg_version, 150_001),
            configure_tables_for_replication_fn:
              Access.get(
                ctx,
                :configure_tables_for_replication_fn,
                &Electric.Postgres.Configuration.configure_publication!/5
              ),
            shape_cache:
              Access.get(ctx, :shape_cache, {Electric.ShapeCache, [stack_id: ctx.stack_id]})
          ]
        ]
      },
      restart: :temporary
    })

    %{
      publication_manager:
        {Electric.Replication.PublicationManager, stack_id: ctx.stack_id, server: server}
    }
  end

  def with_test_publication_manager(_ctx) do
    %{publication_manager: TestPublicationManager.new()}
  end

  def with_noop_publication_manager(_ctx) do
    %{publication_manager: {NoopPublicationManager, []}}
  end

  def with_shape_cache(ctx, additional_opts \\ []) do
    server = :"shape_cache_#{full_test_name(ctx)}"
    consumer_supervisor = :"consumer_supervisor_#{full_test_name(ctx)}"

    start_opts =
      [
        name: server,
        stack_id: ctx.stack_id,
        inspector: ctx.inspector,
        storage: ctx.storage,
        publication_manager: ctx.publication_manager,
        chunk_bytes_threshold: ctx.chunk_bytes_threshold,
        db_pool: ctx.pool,
        registry: ctx.registry,
        log_producer: ctx.shape_log_collector,
        consumer_supervisor: consumer_supervisor
      ]
      |> Keyword.merge(additional_opts)

    start_link_supervised!(%{
      id: consumer_supervisor,
      start: {
        Electric.Shapes.DynamicConsumerSupervisor,
        :start_link,
        [[name: consumer_supervisor, stack_id: ctx.stack_id]]
      },
      restart: :temporary
    })

    start_link_supervised!(%{
      id: start_opts[:name],
      start: {ShapeCache, :start_link, [start_opts]},
      restart: :temporary
    })

    shape_meta_table = ShapeCache.get_shape_meta_table(stack_id: ctx.stack_id)

    shape_cache_opts = [
      stack_id: ctx.stack_id,
      server: server,
      storage: ctx.storage,
      shape_meta_table: shape_meta_table
    ]

    %{
      shape_cache_opts: shape_cache_opts,
      shape_cache: {ShapeCache, shape_cache_opts},
      shape_cache_server: server,
      consumer_supervisor: consumer_supervisor,
      shape_meta_table: shape_meta_table
    }
  end

  def with_lsn_tracker(ctx) do
    Electric.LsnTracker.init(Electric.Postgres.Lsn.from_integer(0), ctx.stack_id)
    %{}
  end

  def with_shape_log_collector(ctx) do
    name = ShapeLogCollector.name(ctx.stack_id)

    start_link_supervised!(%{
      id: name,
      start:
        {ShapeLogCollector, :start_link,
         [[stack_id: ctx.stack_id, inspector: ctx.inspector, persistent_kv: ctx.persistent_kv]]},
      restart: :temporary
    })

    %{shape_log_collector: name}
  end

  def with_slot_name_and_stream_id(_ctx) do
    # Use a random slot name to avoid conflicts
    %{
      slot_name: "electric_test_slot_#{:rand.uniform(10_000)}",
      stream_id: "default"
    }
  end

  def with_inspector(ctx) do
    server =
      start_link_supervised!(
        {EtsInspector,
         stack_id: ctx.stack_id, pool: ctx.db_conn, persistent_kv: ctx.persistent_kv}
      )

    pg_relation_table = EtsInspector.relation_table(stack_id: ctx.stack_id)

    %{
      inspector: {EtsInspector, stack_id: ctx.stack_id, server: server},
      pg_relation_table: pg_relation_table,
      inspector_pid: server
    }
  end

  def with_status_monitor(ctx) do
    start_link_supervised!({Electric.StatusMonitor, ctx.stack_id})
    %{}
  end

  defmodule NoopShapeStatus do
    def initialise(_), do: {:ok, []}
    def list_shapes(_), do: []
    def get_existing_shape(_, _), do: nil
    def add_shape(_, _), do: {:ok, "handle"}
    def initialise_shape(_, _, _, _), do: :ok
    def set_snapshot_xmin(_, _, _), do: :ok
    def mark_snapshot_started(_, _), do: :ok
    def snapshot_started?(_, _), do: false
    def remove_shape(_, _), do: {:ok, nil}
  end

  def with_shape_monitor(ctx) do
    alias Electric.ShapeCache.ShapeStatus

    storage =
      Map.get_lazy(ctx, :storage, fn ->
        %{storage: storage} = with_in_memory_storage(ctx)

        storage
      end)

    publication_manager =
      Map.get_lazy(ctx, :publication_manager, fn ->
        %{publication_manager: publication_manager} = with_test_publication_manager(ctx)
        publication_manager
      end)

    shape_status =
      {ShapeStatus,
       %ShapeStatus{
         shape_meta_table: Electric.ShapeCache.get_shape_meta_table(stack_id: ctx.stack_id)
       }}

    start_link_supervised!(
      {Electric.Shapes.Monitor,
       Keyword.merge(monitor_config(ctx),
         stack_id: ctx.stack_id,
         storage: storage,
         publication_manager: publication_manager,
         shape_status: shape_status
       )}
    )

    %{storage: storage, publication_manager: publication_manager}
  end

  defp monitor_config(ctx) do
    parent = self()

    on_remove =
      Map.get(ctx, :on_shape_remove, fn handle, _pid ->
        send(parent, {Electric.Shapes.Monitor, :remove, handle})
      end)

    on_cleanup =
      Map.get(ctx, :on_shape_cleanup, fn handle ->
        send(parent, {Electric.Shapes.Monitor, :cleanup, handle})
      end)

    [on_remove: on_remove, on_cleanup: on_cleanup]
  end

  def with_complete_stack(ctx) do
    stack_id = full_test_name(ctx)

    kv = %Electric.PersistentKV.Memory{
      parent: self(),
      pid: start_supervised!(Electric.PersistentKV.Memory, restart: :temporary)
    }

    storage =
      {PureFileStorage, stack_id: stack_id, storage_dir: ctx.tmp_dir}

    stack_events_registry = Electric.stack_events_registry()

    ref = Electric.StackSupervisor.subscribe_to_stack_events(stack_id)
    publication_name = "electric_test_pub_#{:erlang.phash2(stack_id)}"

    stack_supervisor =
      start_supervised!(
        {Electric.StackSupervisor,
         stack_id: stack_id,
         stack_events_registry: stack_events_registry,
         chunk_bytes_threshold:
           Map.get(
             ctx,
             :chunk_size,
             Electric.ShapeCache.LogChunker.default_chunk_size_threshold()
           ),
         persistent_kv: kv,
         storage: storage,
         connection_opts: ctx.pooled_db_config,
         replication_opts: [
           connection_opts: ctx.db_config,
           slot_name: "electric_test_slot_#{:erlang.phash2(stack_id)}",
           publication_name: publication_name,
           try_creating_publication?: true,
           slot_temporary?: true
         ],
         pool_opts: [
           backoff_type: :stop,
           max_restarts: 0,
           pool_size: 2
         ],
         tweaks: [
           registry_partitions: 1,
           monitor_opts: monitor_config(ctx)
         ]},
        restart: :temporary,
        significant: false
      )

    # allow a reasonable time for full stack setup to account for
    # potential CI slowness, including PG
    assert_receive {:stack_status, ^ref, :ready}, 2000

    %{
      stack_id: stack_id,
      registry: Electric.StackSupervisor.registry_name(stack_id),
      stack_events_registry: stack_events_registry,
      shape_cache: {ShapeCache, [stack_id: stack_id]},
      persistent_kv: kv,
      stack_supervisor: stack_supervisor,
      storage: storage,
      inspector:
        {EtsInspector, stack_id: stack_id, server: EtsInspector.name(stack_id: stack_id)},
      publication_name: publication_name
    }
  end

  def secure_mode(_ctx) do
    %{secret: "test_secret_#{:erlang.unique_integer()}"}
  end

  def build_router_opts(ctx, overrides \\ []) do
    [
      long_poll_timeout: 4_000,
      max_age: 60,
      stale_age: 300,
      allow_shape_deletion: true,
      secret: ctx[:secret]
    ]
    |> Keyword.merge(
      Electric.StackSupervisor.build_shared_opts(
        stack_id: ctx.stack_id,
        stack_events_registry: ctx.stack_events_registry,
        storage: ctx.storage,
        persistent_kv: ctx.persistent_kv
      )
    )
    |> Keyword.merge(overrides)
    |> Electric.Shapes.Api.plug_opts()
  end
end
