defmodule Eflatbuffers.Schema do
  alias Eflatbuffers.Utils

  @referenced_types [
    :string,
    :byte,
    :ubyte,
    :bool,
    :short,
    :ushort,
    :int,
    :uint,
    :float,
    :long,
    :ulong,
    :double
  ]

  def parse!(schema_str) do
    case parse(schema_str) do
      {:ok, schema} ->
        schema

      {:error, error} ->
        throw({:error, error})
    end
  end

  def parse(schema_str) when is_binary(schema_str) do
    tokens = lexer(schema_str)

    case :schema_parser.parse(tokens) do
      {:ok, data} ->
        {:ok, decorate(data)}

      error ->
        error
    end
  end

  def lexer(schema_str) do
    {:ok, tokens, _} =
      to_charlist(schema_str)
      |> :schema_lexer.string()

    tokens
  end

  # this preprocesses the schema
  # in order to keep the read/write
  # code as simple as possible
  # correlate tables with names
  # and define defaults explicitly
  def decorate({entities, options}) do
    entities_decorated =
      Enum.reduce(
        entities,
        %{},
        # for a tables we transform
        # the types to explicitly signify
        # vectors, tables, and enums
        fn
          {key, {:table, fields}}, acc ->
            Map.put(
              acc,
              key,
              {:table, table_options(fields, entities)}
            )

          # for enums we change the list of options
          # into a map for faster lookup when
          # writing and reading
          {key, {{:enum, type}, fields}}, acc ->
            hash =
              Enum.reduce(
                Enum.with_index(fields),
                %{},
                fn {field, index}, hash_acc ->
                  Map.put(hash_acc, field, index) |> Map.put(index, field)
                end
              )

            Map.put(
              acc,
              key,
              {:enum, %{type: {type, %{default: 0, use_default: true}}, members: hash}}
            )

          {key, {:union, fields}}, acc ->
            hash =
              Enum.reduce(
                Enum.with_index(fields),
                %{},
                fn {field, index}, hash_acc ->
                  Map.put(hash_acc, field, index) |> Map.put(index, field)
                end
              )

            Map.put(acc, key, {:union, %{members: hash}})

          {key, {:struct, fields}}, acc ->
            Map.put(acc, key, {:struct, struct_options(fields, entities)})
        end
      )

    {entities_decorated, options}
  end

  # There are no relevant options for structs, but keep the shape consistent with everything else
  def struct_options(fields, entities) do
    %{
      fields:
        Enum.map(fields, fn
          {key, type} ->
            case Map.get(entities, type) do
              nil ->
                {key, {type, %{}}}

              {{:enum, _enum_type}, _enum_values} ->
                {key, {:enum, %{name: type, use_default: false}}}

              {:struct, _struct_fields} ->
                {key, {:struct, %{name: type}}}
            end
        end),
      largest_scalar: find_largest_scalar(fields, entities)
    }
  end

  def find_largest_scalar(fields, entities, largest_scalar \\ 0) do
    Enum.reduce(fields, largest_scalar, fn
      {_, type}, acc ->
        size =
          case Map.get(entities, type) do
            nil ->
              Utils.scalar_size(type)

            {{:enum, _enum_type}, _enum_values} ->
              1

            {:struct, struct_fields} ->
              find_largest_scalar(struct_fields, entities, acc)
          end

        if size > acc, do: size, else: acc
    end)
  end

  def table_options(fields, entities) do
    fields_and_indices(fields, entities, {0, [], %{}})
  end

  def fields_and_indices([], _, {_, fields, indices}) do
    %{fields: Enum.reverse(fields), indices: indices}
  end

  def fields_and_indices(
        [{field_name, field_value} | fields],
        entities,
        {index, fields_acc, indices_acc}
      ) do
    index_offset = index_offset(field_value, entities)
    decorated_type = decorate_field(field_value, entities)
    index_new = index + index_offset
    fields_acc_new = [{field_name, decorated_type} | fields_acc]
    indices_acc_new = Map.put(indices_acc, field_name, {index, decorated_type})
    fields_and_indices(fields, entities, {index_new, fields_acc_new, indices_acc_new})
  end

  def index_offset(field_value, entities) do
    case is_referenced?(field_value) do
      true ->
        case Map.get(entities, field_value) do
          {:union, _} ->
            2

          _ ->
            1
        end

      false ->
        1
    end
  end

  def decorate_field({:vector, type}, entities) do
    {:vector, %{type: decorate_field(type, entities)}}
  end

  def decorate_field(field_value, entities) do
    case is_referenced?(field_value) do
      true ->
        decorate_referenced_field(field_value, entities)

      false ->
        decorate_field(field_value)
    end
  end

  def decorate_referenced_field(field_value, entities) do
    case Map.get(entities, field_value) do
      nil ->
        throw({:error, {:entity_not_found, field_value}})

      {:table, _} ->
        {:table, %{name: field_value}}

      {{:enum, _}, _} ->
        {:enum, %{name: field_value}}

      {:union, _} ->
        {:union, %{name: field_value}}

      {:struct, _} ->
        {:struct, %{name: field_value}}
    end
  end

  def decorate_field({type, default}) do
    {type, %{default: default, use_default: true}}
  end

  def decorate_field(:bool) do
    {:bool, %{default: false, use_default: true}}
  end

  def decorate_field(:string) do
    {:string, %{}}
  end

  def decorate_field(type) do
    {type, %{default: 0, use_default: true}}
  end

  def is_referenced?({type, _default}) do
    is_referenced?(type)
  end

  def is_referenced?(type) do
    not Enum.member?(@referenced_types, type)
  end
end
