defmodule Handbeam.JsonSafeTest do
  use ExUnit.Case, async: true

  alias Handbeam.JsonSafe
  alias Handbeam.Memory.Engram

  test "converts tuples and structs into JSON-encodable values" do
    value = %{
      details: %{
        count: 1,
        range: {0, 0},
        results: [
          %Engram{
            id: 4,
            content: "User likes Cantonese food",
            kind: :preference,
            short_term: true,
            expires_at: ~U[2026-05-22 12:34:08Z],
            metadata: %{scope: "workspace"},
            source_synapses: [],
            target_synapses: []
          }
        ]
      }
    }

    safe = JsonSafe.normalize(value)

    assert safe["details"]["range"] == [0, 0]

    assert [%{"content" => "User likes Cantonese food", "kind" => "preference"}] =
             safe["details"]["results"]

    assert {:ok, _json} = Jason.encode(safe)
  end
end
