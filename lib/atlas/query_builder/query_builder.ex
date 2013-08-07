defmodule Atlas.QueryBuilder do
  alias Atlas.Database.Client
  alias Atlas.QueryBuilder.RelationProcessor

  defrecord Relation, from: nil, wheres: [], select: nil, includes: [], joins: [], limit: nil,
                      offset: nil, order_by: nil, order_by_direction: nil, count: false


  @doc """
  Converts list into comma delimited binding placeholders for query.
  Useful when transforming list into query bindings

  Examples

    iex> Model.list_to_binding_placeholders([1,2,3])
    "?, ?, ?"
  """
  def list_to_binding_placeholders([]), do: ""
  def list_to_binding_placeholders(collection) do
    1..Enum.count(collection)
    |> Enum.map_join(", ", fn i -> "?" end)
  end

  defmacro __using__(_options) do
    quote do
      import unquote(__MODULE__)
      import Client, only: [adapter: 0]

      @before_compile unquote(__MODULE__)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def new_base_relation do
        Relation.new(from: @table)
      end

      def scoped do
        new_base_relation
      end

      def where(kwlist) when is_list(kwlist) do
        where new_base_relation, kwlist
      end
      def where(relation = Relation[], kwlist) when is_list(kwlist) do
        relation.wheres(relation.wheres ++ [kwlist_to_bound_query(kwlist)])
      end

      def where(query_string, values) when is_binary(query_string) do
        where new_base_relation, query_string, List.flatten([values])
      end
      def where(relation = Relation[], query_string, values) when is_binary(query_string) do
        relation.wheres(relation.wheres ++ [{query_string, List.flatten([values])}])
      end
      def where(query_string) when is_binary(query_string) do
        where(query_string, [])
      end
      def where(relation = Relation[], query_string) when is_binary(query_string) do
        where(relation, query_string, [])
      end

      def first do
        first new_base_relation
      end
      def first(relation) do
        relation.limit(1) |> to_records |> Enum.first
      end

      def last do
        last new_base_relation
      end
      def last(relation) do
        relation.update(limit: 1) |> swap_order_direction |> to_records |> Enum.first
      end

      def order(options) do
        order new_base_relation, options
      end
      def order(relation, field) when is_atom(field) or is_binary(field) do
        relation.order_by(field)
      end
      def order(relation, [{field, direction}]) do
        relation.update(order_by: field, order_by_direction: direction)
      end
      def order_direction(relation, direction) do
        relation.order_by_direction(direction)
      end
      def swap_order_direction(relation) do
        relation.order_by_direction(case relation.order_by_direction do
          :asc  -> :desc
          :desc -> :asc
          _ -> :desc
        end)
      end

      def limit(number) do
        limit new_base_relation, number
      end
      def limit(relation, number) do
        relation.limit(number)
      end

      def offset(number) do
        offset new_base_relation, number
      end
      def offset(relation, number) do
        relation.offset(number)
      end

      def select(column), do: select(new_base_relation, column)
      def select(relation, column) do
        relation.select(to_binary(column))
      end

      def count, do: count(new_base_relation)

      def count(relation) do
        relation = relation.update(count: true, order_by: nil, order_by_direction: nil)
        {sql, args} = relation |> to_prepared_sql
        {:ok, results} = Client.execute_prepared_query(sql, args)

        results
        |> Enum.first
        |> Keyword.get(:count)
        |> binary_to_integer
      end

      def to_records(relation) do
        relation
        |> to_prepared_sql
        |> find_by_sql
      end

      def find_by_sql({sql, bound_args}) do
        {:ok, results} = Client.execute_prepared_query(sql, bound_args)
        results |> raw_query_results_to_records
      end

      @doc """
      Convert a keyword list of key, val equalities into prepared sql bound query

      Examples
      ```
      kwlist_to_bound_query(email: "foo@bar.com", archived: [false])
      { "\"users\".\"email\" = ? AND \"users\".\"archived\" IN(?, ?)", ["foo@bar.com, false] }
      ```

      Returns Tuple { bound_query_string, bound_values }
      """
      def kwlist_to_bound_query(equalities) do
        {query_strings, values} = equalities
        |> Enum.with_index
        |> Enum.reverse
        |> Enum.map(equality_to_bound_query(&1))
        |> Enum.reduce({[], []}, fn {query_string, value}, {query_acc, values} ->
          {[query_string | query_acc], [value | values]}
        end)

        {Enum.join(query_strings, " \n"), values}
      end
      defp equality_to_bound_query({{key, values}, index}) when is_list(values) do
        cast_values = Enum.map values, fn value ->
          value_to_field_type(value, field_type_for_name(key))
        end
        if index > 0 do
          {"AND #{quoted_namespaced_column(key)} IN(?)", cast_values}
        else
          {"#{quoted_namespaced_column(key)} IN(?)", cast_values}
        end
      end
      defp equality_to_bound_query({{key, value}, index}) do
        cast_val = value_to_field_type(value, field_type_for_name(key))
        if index > 0 do
          {"AND #{quoted_namespaced_column(key)} = ?", cast_val}
        else
          {"#{quoted_namespaced_column(key)} = ?", cast_val}
        end
      end

      defp quoted_namespaced_column(column) do
        if @table do
          "#{quote_tablename}.#{adapter.quote_column(column)}"
        else
          adapter.quote_column(column)
        end
      end

      def to_prepared_sql(relation) do
        RelationProcessor.to_prepared_sql(relation)
      end

      defp quote_tablename, do: adapter.quote_tablename(@table)
    end
  end
end
