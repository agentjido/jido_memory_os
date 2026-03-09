defmodule Jido.MemoryOS.ContextBudgetTest do
  use ExUnit.Case, async: true

  alias Jido.MemoryOS.ContextBudget

  describe "dynamic/1" do
    test "returns max budget for first turn" do
      assert ContextBudget.dynamic(turn_count: 0) == 8_000
    end

    test "returns max budget for early turns" do
      assert ContextBudget.dynamic(turn_count: 1) == 8_000
    end

    test "budget decreases as turns increase" do
      early = ContextBudget.dynamic(turn_count: 10)
      late = ContextBudget.dynamic(turn_count: 400)
      assert early > late
    end

    test "never goes below 1,000" do
      assert ContextBudget.dynamic(turn_count: 1000) == 1_000
    end

    test "defaults to turn_count 0 when not provided" do
      assert ContextBudget.dynamic() == 8_000
      assert ContextBudget.dynamic([]) == 8_000
    end
  end

  describe "resolve/3" do
    test "returns static integer as-is" do
      assert ContextBudget.resolve(5_000) == 5_000
    end

    test "calls function with opts" do
      fun = fn opts -> Keyword.get(opts, :turn_count, 0) * 100 end
      assert ContextBudget.resolve(fun, [turn_count: 3]) == 300
    end

    test "returns default when nil" do
      assert ContextBudget.resolve(nil) == 4_000
      assert ContextBudget.resolve(nil, [], 6_000) == 6_000
    end

    test "returns default for unexpected types" do
      assert ContextBudget.resolve("invalid") == 4_000
    end
  end
end
