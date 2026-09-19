defmodule Handbeam.Agent.CandidateQueueTest do
  use ExUnit.Case, async: true

  alias Handbeam.Agent.{CandidateQueue, Message}

  describe "enqueue/drain" do
    test "drains steer messages FIFO" do
      {:ok, queue} = CandidateQueue.start_link(session_id: "cq-steer", owner: self())

      assert :ok = CandidateQueue.enqueue(queue, "first", deliver_as: :steer)
      assert :ok = CandidateQueue.enqueue(queue, "second", deliver_as: :steer)

      assert [%Message{role: :user, content: "first"}, %Message{role: :user, content: "second"}] =
               CandidateQueue.drain_steer(queue)

      assert CandidateQueue.drain_steer(queue) == []
    end

    test "keeps steer and follow_up in separate FIFO queues" do
      {:ok, queue} = CandidateQueue.start_link(session_id: "cq-kinds", owner: self())

      assert :ok = CandidateQueue.enqueue(queue, "steer", deliver_as: :steer)
      assert :ok = CandidateQueue.enqueue(queue, "follow", deliver_as: :follow_up)

      assert [%Message{content: "steer"}] = CandidateQueue.drain_steer(queue)
      assert [%Message{content: "follow"}] = CandidateQueue.drain_follow_up(queue)
    end

    test "enforces max size across pending run queues" do
      {:ok, queue} = CandidateQueue.start_link(session_id: "cq-full", owner: self(), max_size: 2)

      assert :ok = CandidateQueue.enqueue(queue, "one", deliver_as: :steer)
      assert :ok = CandidateQueue.enqueue(queue, "two", deliver_as: :follow_up)
      assert {:error, :queue_full} = CandidateQueue.enqueue(queue, "three", deliver_as: :steer)
    end

    test "seal rejects later enqueue" do
      {:ok, queue} = CandidateQueue.start_link(session_id: "cq-seal", owner: self())

      assert :ok = CandidateQueue.enqueue(queue, "before", deliver_as: :steer)
      assert :ok = CandidateQueue.seal(queue)
      assert {:error, :sealed} = CandidateQueue.enqueue(queue, "after", deliver_as: :steer)
      assert [%Message{content: "before"}] = CandidateQueue.drain_steer(queue)
    end

    test "reports pending messages" do
      {:ok, queue} = CandidateQueue.start_link(session_id: "cq-pending", owner: self())

      refute CandidateQueue.has_pending?(queue)
      assert :ok = CandidateQueue.enqueue(queue, "hello", deliver_as: :follow_up)
      assert CandidateQueue.has_pending?(queue)
      assert [_] = CandidateQueue.drain_follow_up(queue)
      refute CandidateQueue.has_pending?(queue)
    end

    test "atomically drains pending messages or seals an empty queue" do
      {:ok, queue} = CandidateQueue.start_link(session_id: "cq-take-or-seal", owner: self())

      assert :ok = CandidateQueue.enqueue(queue, "steer", deliver_as: :steer)
      assert :ok = CandidateQueue.enqueue(queue, "follow", deliver_as: :follow_up)

      assert {:pending,
              %{
                steer: [%Message{content: "steer"}],
                follow_up: [%Message{content: "follow"}]
              }} = CandidateQueue.take_pending_or_seal(queue)

      assert :sealed = CandidateQueue.take_pending_or_seal(queue)
      assert {:error, :sealed} = CandidateQueue.enqueue(queue, "too late")
    end
  end
end
