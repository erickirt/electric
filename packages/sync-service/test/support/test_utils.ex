defmodule Support.TestUtils do
  alias Electric.Replication.LogOffset
  alias Electric.LogItems
  alias Electric.Replication.Changes

  @doc """
  Preprocess a list of `Changes.data_change()` structs in the same way they
  are preprocessed before reaching storage.
  """
  def changes_to_log_items(changes, opts \\ []) do
    pk = Keyword.get(opts, :pk, ["id"])
    xid = Keyword.get(opts, :xid, 1)
    replica = Keyword.get(opts, :replica, :default)

    changes
    |> Enum.map(&Changes.fill_key(&1, pk))
    |> Enum.flat_map(&LogItems.from_change(&1, xid, pk, replica))
    |> Enum.map(fn {offset, item} ->
      {offset, item.key, item.headers.operation, Jason.encode!(item)}
    end)
  end

  def with_electric_instance_id(ctx) do
    %{electric_instance_id: String.to_atom(full_test_name(ctx))}
  end

  def full_test_name(ctx) do
    "#{inspect(ctx.module)} #{ctx.test}"
  end

  def ins(opts) do
    offset = Keyword.fetch!(opts, :offset) |> LogOffset.new()
    relation = Keyword.get(opts, :relation, {"public", "test_table"})
    record = Keyword.fetch!(opts, :rec) |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
    %Changes.NewRecord{relation: relation, record: record, log_offset: offset}
  end

  def del(opts) do
    offset = Keyword.fetch!(opts, :offset) |> LogOffset.new()
    relation = Keyword.get(opts, :relation, {"public", "test_table"})

    old_record =
      Keyword.fetch!(opts, :rec) |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    %Changes.DeletedRecord{relation: relation, old_record: old_record, log_offset: offset}
  end

  def upd(opts) do
    offset = Keyword.fetch!(opts, :offset) |> LogOffset.new()
    relation = Keyword.get(opts, :relation, {"public", "test_table"})

    {old, new} =
      Enum.reduce(Keyword.fetch!(opts, :rec), {%{}, %{}}, fn
        {k, {old, new}}, {old_acc, new_acc} ->
          {Map.put(old_acc, to_string(k), to_string(old)),
           Map.put(new_acc, to_string(k), to_string(new))}

        {k, v}, {old, new} ->
          {Map.put(old, to_string(k), to_string(v)), Map.put(new, to_string(k), to_string(v))}
      end)

    Changes.UpdatedRecord.new(
      relation: relation,
      old_record: old,
      record: new,
      log_offset: offset
    )
  end

  def set_status_to_active(%{stack_id: stack_id}) do
    Electric.StatusMonitor.mark_pg_lock_acquired(stack_id, self())
    Electric.StatusMonitor.mark_replication_client_ready(stack_id, self())
    Electric.StatusMonitor.mark_connection_pool_ready(stack_id, self())
    Electric.StatusMonitor.mark_shape_log_collector_ready(stack_id, self())
    Electric.StatusMonitor.wait_for_messages_to_be_processed(stack_id)
  end

  def set_status_to_errored(%{stack_id: stack_id}, error_message) do
    Electric.StatusMonitor.mark_pg_lock_as_errored(stack_id, error_message)
  end
end
