defmodule Electric.Replication.Eval.ParserTest do
  use ExUnit.Case, async: true

  alias Electric.Replication.Eval.Env.ExplicitCasts
  alias Electric.Replication.Eval.Parser
  alias Electric.Replication.Eval.Parser.{Const, Func, Ref}
  alias Electric.Replication.Eval.Env
  alias Electric.Replication.Eval.Expr

  @int_to_bool_casts %{
    {:int4, :bool} => {ExplicitCasts, :int4_to_bool},
    {:bool, :int4} => {ExplicitCasts, :bool_to_int4}
  }

  describe "parse_and_validate_expression/3 basics" do
    test "should correctly parse constants" do
      assert {:ok, %Expr{eval: result}} = Parser.parse_and_validate_expression("TRUE")
      assert %Const{value: true} = result
    end

    test "should work with unknown constants" do
      assert {:ok, %Expr{eval: result}} = Parser.parse_and_validate_expression("'test'")
      assert %Const{value: "test", type: :text} = result
    end

    test "should correctly parse type casts on constants" do
      assert {:error, "At location 0: unknown cast from type int4 to type bool"} =
               Parser.parse_and_validate_expression("1::boolean", env: Env.empty())
    end

    test "should fail on references that don't exist" do
      assert {:error, "At location 0: unknown reference test"} =
               Parser.parse_and_validate_expression(~S|"test"|)
    end

    test "should fail helpfully on references that might exist" do
      assert {:error, "At location 0: unknown reference test - did you mean `this.test`?"} =
               Parser.parse_and_validate_expression(~S|"test"|,
                 refs: %{["this", "test"] => :bool}
               )
    end

    test "should correctly parse a known reference" do
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|"test"|, refs: %{["test"] => :bool})

      assert %Ref{path: ["test"], type: :bool} = result
    end

    test "should correctly cast an enum to text" do
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|foo::text|,
                 refs: %{["foo"] => {:enum, "foo_enum"}},
                 env: Env.empty()
               )

      assert %Ref{path: ["foo"], type: :text} = result
    end

    test "should correctly parse a boolean function" do
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|"test" OR true|,
                 refs: %{["test"] => :bool}
               )

      assert %Func{name: "or", args: [%Ref{path: ["test"], type: :bool}, %Const{value: true}]} =
               result
    end

    test "should correctly parse a cast on reference" do
      env = Env.empty(explicit_casts: @int_to_bool_casts)

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|"test"::integer|,
                 refs: %{["test"] => :bool},
                 env: env
               )

      assert %Func{name: "bool_to_int4", args: [%Ref{path: ["test"], type: :bool}]} = result
    end

    test "should correctly cast a const at compile time" do
      env = Env.empty(explicit_casts: @int_to_bool_casts)

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|true::integer|,
                 refs: %{["test"] => :bool},
                 env: env
               )

      assert %Const{type: :int4, value: 1} = result
    end

    test "should correctly process a cast chain" do
      env = Env.empty(explicit_casts: @int_to_bool_casts)

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|true::integer::bool::integer::bool::integer|,
                 env: env
               )

      assert %Const{type: :int4, value: 1} = result
    end

    test "should correctly parse a unary operator" do
      env =
        Env.empty(
          operators: %{
            {~s|"-"|, 1} => [
              %{args: [:numeric], returns: :numeric, implementation: & &1, name: "-"}
            ]
          }
        )

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|- "test"|,
                 refs: %{["test"] => :int4},
                 env: env
               )

      assert %Func{name: "-", args: [%Ref{path: ["test"], type: :int4}]} = result
    end

    test "should correctly parse a binary operator" do
      env =
        Env.empty(
          operators: %{
            {~s|"+"|, 2} => [
              %{args: [:numeric, :numeric], returns: :numeric, implementation: & &1, name: "+"}
            ]
          }
        )

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|"test" + "test"|,
                 refs: %{["test"] => :int4},
                 env: env
               )

      assert %Func{
               name: "+",
               args: [%Ref{path: ["test"], type: :int4}, %Ref{path: ["test"], type: :int4}]
             } = result
    end

    test "should correctly cast unknowns to knowns for a binary operator" do
      env =
        Env.empty(
          operators: %{
            {~s|"+"|, 2} => [
              %{args: [:int4, :int4], returns: :int4, implementation: & &1, name: "+"}
            ]
          }
        )

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|"test" + '4'|,
                 refs: %{["test"] => :int4},
                 env: env
               )

      assert %Func{
               name: "+",
               args: [%Ref{path: ["test"], type: :int4}, %Const{type: :int4, value: 4}]
             } = result
    end

    test "should correctly pick an overload between operators" do
      env =
        Env.empty(
          operators: %{
            {~s|"+"|, 2} => [
              %{args: [:int8, :int8], returns: :int8, implementation: &Kernel.+/2, name: "int4"},
              %{
                args: [:float8, :float8],
                returns: :float8,
                implementation: &Kernel.+/2,
                name: "float8"
              },
              %{args: [:text, :text], returns: :text, implementation: &Kernel.<>/2, name: "text"}
            ]
          }
        )

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|"test" + '4'|,
                 refs: %{["test"] => :int4},
                 env: env
               )

      assert %Func{
               name: "float8",
               args: [%Ref{path: ["test"], type: :int4}, %Const{type: :float8, value: 4.0}]
             } = result
    end

    test "should fail on a function with aggregation" do
      assert {:error, "At location 0: aggregation is not supported in this context"} =
               Parser.parse_and_validate_expression(~S|ceil(DISTINCT "test")|,
                 refs: %{
                   ["test"] => :int4
                 }
               )
    end

    test "should correctly parse a function call" do
      env =
        Env.new(
          funcs: %{
            {"ceil", 1} => [
              %{args: [:numeric], returns: :numeric, implementation: & &1, name: "-"}
            ]
          }
        )

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|ceil("test")|,
                 refs: %{["test"] => :int4},
                 env: env
               )

      assert %Func{name: "-", args: [%Ref{path: ["test"], type: :int4}]} = result
    end

    test "should reduce down immutable function calls that have only constants" do
      env =
        Env.empty(
          operators: %{
            {~s|"+"|, 2} => [
              %{args: [:int4, :int4], returns: :int4, implementation: &Kernel.+/2, name: "+"},
              %{
                args: [:float8, :float8],
                returns: :float8,
                implementation: &Kernel.+/2,
                name: "+"
              },
              %{args: [:text, :text], returns: :text, implementation: &Kernel.<>/2, name: "||"}
            ]
          }
        )

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|1 + 1|,
                 refs: %{["test"] => :int4},
                 env: env
               )

      assert %Const{value: 2, type: :int4} = result
    end

    test "should correctly apply a commutative overload operator by reversing the arguments" do
      env =
        Env.empty(
          operators: %{
            {~s|"+"|, 2} => [
              %{
                name: "create timestamp",
                args: [:time, :date],
                commutative_overload?: true,
                returns: :timestamp,
                implementation: &NaiveDateTime.new!/2
              }
            ]
          }
        )

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|time '20:00:00' + date '2024-01-01'|,
                 refs: %{["test"] => :int4},
                 env: env
               )

      assert %Const{value: ~N[2024-01-01 20:00:00], type: :timestamp} = result
    end

    test "should work with IS [NOT] DISTINCT FROM clauses" do
      env = Env.new()

      for {expr, expected} <- [
            {~S|1 IS DISTINCT FROM 2|, true},
            {~S|1 IS DISTINCT FROM NULL|, true},
            {~S|NULL IS DISTINCT FROM NULL|, false},
            {~S|1 IS NOT DISTINCT FROM 2|, false},
            {~S|'foo' IS NOT DISTINCT FROM NULL|, false},
            {~S|NULL IS NOT DISTINCT FROM NULL|, true}
          ] do
        assert {{:ok, %Expr{eval: result}}, ^expr} =
                 {Parser.parse_and_validate_expression(expr, env: env), expr}

        assert {%Const{value: ^expected, type: :bool}, ^expr} = {result, expr}
      end
    end

    test "should work with IS [NOT] UNKNOWN" do
      env = Env.new()

      for {expr, expected} <- [
            {~S|true IS UNKNOWN|, false},
            {~S|true IS NOT UNKNOWN|, true},
            {~S|NULL::boolean IS UNKNOWN|, true},
            {~S|NULL::boolean IS NOT UNKNOWN|, false},
            {~S|NULL IS UNKNOWN|, true},
            {~S|NULL IS NOT UNKNOWN|, false}
          ] do
        assert {{:ok, %Expr{eval: result}}, ^expr} =
                 {Parser.parse_and_validate_expression(expr, env: env), expr}

        assert {%Const{value: ^expected, type: :bool}, ^expr} = {result, expr}
      end
    end

    test "should work with LIKE clauses" do
      env = Env.new()

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|'hello' NOT LIKE 'hell\%' AND 'hello' LIKE 'h%o' |,
                 env: env
               )

      assert %Const{value: true, type: :bool} = result
    end

    test "should work with BETWEEN clauses" do
      env = Env.new()

      for {expr, expected} <- [
            {~S|0 BETWEEN 1 AND 3|, false},
            {~S|1 BETWEEN 1 AND 3|, true},
            {~S|2 BETWEEN 1 AND 3|, true},
            {~S|3 BETWEEN 1 AND 3|, true},
            {~S|4 BETWEEN 1 AND 3|, false},
            {~S|2 NOT BETWEEN 1 AND 3|, false},
            {~S|1 BETWEEN 3 AND 1|, false},
            {~S|1 NOT BETWEEN 3 AND 1|, true},
            {~S|2 BETWEEN SYMMETRIC 3 AND 1|, true},
            {~S|2 NOT BETWEEN SYMMETRIC 3 AND 1|, false},
            {~S|'2024-07-31'::date BETWEEN '2024-07-01'::date AND '2024-07-31'::date|, true},
            {~S|'2024-07-31'::date NOT BETWEEN '2024-07-01'::date AND '2024-07-31'::date|, false},
            {~S|'2024-06-30'::date BETWEEN '2024-07-01'::date AND '2024-07-31'::date|, false},
            {~S|'2024-06-30'::date NOT BETWEEN '2024-07-01'::date AND '2024-07-31'::date|, true},
            {~S|'2024-07-15'::date BETWEEN SYMMETRIC '2024-07-31'::date AND '2024-07-01'::date|,
             true},
            {~S|'2024-07-15'::date NOT BETWEEN SYMMETRIC '2024-07-31'::date AND '2024-07-01'::date|,
             false}
          ] do
        assert {:ok, %Expr{eval: result}} =
                 Parser.parse_and_validate_expression(expr, env: env)

        assert %Const{value: ^expected, type: :bool} = result
      end
    end

    test "should work with explicit casts" do
      env = Env.new()

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|1::boolean|, env: env)

      assert %Const{value: true, type: :bool} = result
    end

    test "should work with IN clauses" do
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|1 IN (1, 2, 3)|)

      assert %Const{value: true, type: :bool} = result
    end

    test "should work with NOT IN clauses" do
      env = Env.new()

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|'test' NOT IN ('hello', 'world')|,
                 env: env
               )

      assert %Const{value: true, type: :bool} = result
    end

    test "should work with IN clauses when one of the options is NULL (by converting everything to NULL)" do
      # https://www.postgresql.org/docs/current/functions-comparisons.html#FUNCTIONS-COMPARISONS-IN-SCALAR
      env = Env.new()

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|'test' IN ('hello', NULL)|,
                 env: env
               )

      assert %Const{value: nil, type: :bool} = result
    end

    test "should not allow subqueries in IN clauses" do
      env = Env.new()

      assert {:error, "At location 5: subqueries are not supported"} =
               Parser.parse_and_validate_expression(
                 ~S|test IN (SELECT val FROM tester)|,
                 refs: %{["test"] => :int4},
                 env: env
               )
    end

    test "should support complex operations with dates" do
      env = Env.new()

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|date '2024-01-01' < interval '1 month 1 hour' + date '2023-12-01'|,
                 env: env
               )

      assert %Const{value: true, type: :bool} = result
    end

    test "should support `AT TIME ZONE`" do
      env = Env.new()

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|timestamp '2001-02-16 20:38:40' at time zone 'America/Denver' = '2001-02-17 03:38:40+00'|,
                 env: env
               )

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|timestamp with time zone '2001-02-16 20:38:40+03' at time zone 'America/Denver' = '2001-02-16 10:38:40'|,
                 env: env
               )

      assert %Const{value: true, type: :bool} = result
    end

    test "should support IS [NOT] NULL" do
      env = Env.new()

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|null IS NULL|, env: env)

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|false IS NOT NULL|, env: env)

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|(1 = NULL) IS NULL|, env: env)

      assert %Const{value: true, type: :bool} = result
    end

    test "should support IS [NOT] TRUE/FALSE" do
      env = Env.new()

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|'true' IS TRUE|, env: env)

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|false IS NOT TRUE|, env: env)

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|null IS NOT FALSE|, env: env)

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|null IS FALSE|, env: env)

      assert %Const{value: false, type: :bool} = result

      assert {:error, "At location 2: argument of IS TRUE must be bool, not int4"} =
               Parser.parse_and_validate_expression(~S|1 IS TRUE|, env: env)
    end

    test "should parse array constants" do
      # TODO: Does not support arbitrary bounds input syntax yet,
      #       e.g. '[1:1][-2:-1][3:5]={{{1,2,3},{4,5,6}}}'::int[]
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|'{{1   },{2},{"3"}}'::int[]|)

      assert %Const{value: [[1], [2], [3]], type: {:array, :int4}} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|ARRAY[ARRAY[1, 2], ARRAY['3', 2 + 2]]|)

      assert %Const{value: [[1, 2], [3, 4]], type: {:array, :int4}} = result

      assert {:error, "At location 0: ARRAY types int4[] and int4 cannot be matched"} =
               Parser.parse_and_validate_expression(~S|ARRAY[1, ARRAY['3', 2 + 2]]|)
    end

    test "should recast a nested array" do
      # as-is recast
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|('{{1},{2},{"3"}}'::int[])::bigint[]|)

      assert %Const{value: [[1], [2], [3]], type: {:array, :int8}} = result

      # with a cast function
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|('{{1},{2},{"3"}}'::text[])::bigint[]|)

      assert %Const{value: [[1], [2], [3]], type: {:array, :int8}} = result
    end

    test "should work with array access" do
      # Including mixed notation, float constants, and text castable to ints
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|('{1,2,3}'::int[])[1][1:'2'][2.2:2.3][:]|)

      assert %Const{value: [], type: {:array, :int4}} = result

      # Returns NULL if any of indices are NULL
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|('{1,2,3}'::int[])[1][1:'2'][2.2:2.3][:][NULL:NULL]|
               )

      assert %Const{value: nil, type: {:array, :int4}} = result

      # Also works when there are no slices
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(
                 ~S|('{{{1}},{{2}},{{3}}}'::int[])[1]['1'][1.4]|
               )

      assert %Const{value: 1, type: :int4} = result

      # And correctly works with expressions as indices
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|('{{1},{2},{3}}'::int[])[2][2 - 1]|)

      assert %Const{value: 2, type: :int4} = result
    end

    test "should support array ANY/ALL" do
      assert {:error, "At location 9: argument of ANY must be an array"} =
               Parser.parse_and_validate_expression(~S|3 > ANY (3)|)

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|3 > ANY ('{1, 2, 3}')|)

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|1::bigint = ANY ('{1,2}'::int[])|)

      assert %Const{value: true, type: :bool} = result

      # Including implicit casts and nested arrays
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|4.1 > ALL ('{{1}, {2}, {3}}'::int[])|)

      assert %Const{value: true, type: :bool} = result
    end
  end

  describe "parse_and_validate_expression/3 default env" do
    test "can compare integers" do
      assert {:ok, _} =
               Parser.parse_and_validate_expression(~S|id != 1|, refs: %{["id"] => :int8})

      assert {:ok, _} =
               Parser.parse_and_validate_expression(~S|id <> 1|, refs: %{["id"] => :int8})

      assert {:ok, _} = Parser.parse_and_validate_expression(~S|id > 1|, refs: %{["id"] => :int8})
      assert {:ok, _} = Parser.parse_and_validate_expression(~S|id < 1|, refs: %{["id"] => :int8})

      assert {:ok, _} =
               Parser.parse_and_validate_expression(~S|id >= 1|, refs: %{["id"] => :int8})

      assert {:ok, _} =
               Parser.parse_and_validate_expression(~S|id <= 1|, refs: %{["id"] => :int8})

      assert {:ok, _} = Parser.parse_and_validate_expression(~S|id = 1|, refs: %{["id"] => :int8})
    end

    test "implements common array operators: @>, <@, &&, ||" do
      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|'{1,2,3}'::int[] @> '{2,1,2}'|)

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|'{1,2,3}'::int[] <@ '{1,2,2}'::int[]|)

      assert %Const{value: false, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S|'{1,2,1}'::int[] && '{2,3,4}'::int[]|)

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S"'{1,2,1}'::int[] || '{2,3,4}'")

      assert %Const{value: [1, 2, 1, 2, 3, 4], type: {:array, :int4}} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S"('1'::bigint || '{2,3,4}'::int[]) || 5")

      assert %Const{value: [1, 2, 3, 4, 5], type: {:array, :int8}} = result

      assert {:ok, %Expr{eval: result}} =
               Parser.parse_and_validate_expression(~S"array_ndims('{{1,2,3},{4,5,6}}')")

      assert %Const{value: 2, type: :int4} = result
    end

    test "does correct operator inference for array polymorphic types" do
      assert {:error, "At location 17: Could not select an operator overload"} =
               Parser.parse_and_validate_expression(~S|'{1,2,3}'::int[] @> '{2,1,2}'::bigint[]|)

      assert {:error, "At location 17: Could not select an operator overload"} =
               Parser.parse_and_validate_expression(~S|'{1,2,3}'::int[] @> '{2,1,2}'::text[]|)

      assert {:error, "At location 17: Could not select an operator overload"} =
               Parser.parse_and_validate_expression(~S/'{1,2,3}'::int[] || '{2,1,2}'::text[]/)
    end
  end

  describe "parse_and_validate_expression/3 with parameters" do
    test "uses parameters and save a parsed value" do
      assert {:ok, %Expr{eval: result, query: query}} =
               Parser.parse_and_validate_expression(~S|'{1,2}'::int[] @> $1|,
                 params: %{"1" => "{2}"},
                 refs: %{
                   ["id"] => {:array, :int8}
                 }
               )

      assert query == ~S|'{1,2}'::int[] @> '{2}'::int4[]|

      assert %Const{value: true, type: :bool} = result

      assert {:ok, %Expr{eval: result, query: query}} =
               Parser.parse_and_validate_expression(~S|1 > $1|,
                 params: %{"1" => "0"},
                 refs: %{
                   ["id"] => {:array, :int8}
                 }
               )

      assert %Const{value: true, type: :bool} = result
      assert query == ~S|1 > '0'::int4|
    end

    test "fails if parameters can't resolve to same type" do
      assert {:error, "At location 16: invalid syntax for type int4: test"} =
               Parser.parse_and_validate_expression(~S"$1 > 5 AND $1 + 'test' > 10",
                 params: %{"1" => "1"}
               )
    end

    test "fails if one of parameters is not provided" do
      assert {:error, "At location 0: parameter $1 was not provided"} =
               Parser.parse_and_validate_expression(~S"$1 > 5")
    end

    test "fails if query misses a parameter position" do
      assert {:error,
              "At location 0: expression is missing $1 - parameters should be numbered sequentially"} =
               Parser.parse_and_validate_expression(~S"$2 > 5", params: %{"2" => "2"})
    end

    test "fails if an unused parameter is provided" do
      assert {:error, "At location 0: parameter value for $2 was not used"} =
               Parser.parse_and_validate_expression(~S"$1 > 5", params: %{"1" => "1", "2" => "2"})
    end
  end
end
