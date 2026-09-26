defmodule Handbeam.Agent.AdvisorTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.Advisor

  # Failure list:
  # - the Delegation wrapper JSON is not the advisor verdict
  # - the child report string is what consult and review parse

  test "child_text returns the advisor report, not the delegation wrapper" do
    wrapper = %{
      status: :completed,
      child_conversation_id: "child",
      report: ~s({"verdict":"pass","findings":[]})
    }

    assert Advisor.child_text({:ok, "Delegated report\n{}", wrapper}) ==
             ~s({"verdict":"pass","findings":[]})
  end

  test "a wrapper without a report is not treated as advisor text" do
    assert Advisor.child_text({:ok, ~s({"status":"completed"}), %{status: :completed}}) == nil
  end
end
