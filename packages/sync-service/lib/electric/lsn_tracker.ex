defmodule Electric.LsnTracker do
  alias Electric.Postgres.Lsn

  def init(last_processed_lsn, stack_id) do
    create_table(stack_id)

    set_last_processed_lsn(last_processed_lsn, stack_id)
  end

  @spec set_last_processed_lsn(Lsn.t() | non_neg_integer(), String.t()) :: :ok
  def set_last_processed_lsn(lsn, stack_id) when is_struct(lsn, Lsn) do
    stack_id
    |> table()
    |> :ets.insert({:last_processed_lsn, lsn})
  end

  def set_last_processed_lsn(lsn, stack_id) when is_integer(lsn) do
    set_last_processed_lsn(Lsn.from_integer(lsn), stack_id)
  end

  @spec get_last_processed_lsn(String.t()) :: Lsn.t()
  def get_last_processed_lsn(stack_id) do
    [last_processed_lsn: lsn] =
      stack_id
      |> table()
      |> :ets.lookup(:last_processed_lsn)

    lsn
  end

  # make this idempotent to avoid problems in tests
  defp create_table(stack_id) do
    table = table(stack_id)

    case :ets.info(table, :id) do
      :undefined ->
        :ets.new(table, [:protected, :named_table])

      ref when is_reference(ref) ->
        :ok
    end
  end

  defp table(stack_id) do
    :"#{stack_id}:lsn_tracker"
  end
end
