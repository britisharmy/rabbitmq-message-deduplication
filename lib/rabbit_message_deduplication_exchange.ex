# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2017-2018, Matteo Cafasso.
# All rights reserved.

defmodule RabbitMQ.MessageDeduplicationPlugin.Exchange do
  @moduledoc """
  This module adds support for deduplication exchanges.

  Messages carrying the `x-deduplication-header` header will be deduplicated
  if a message with the same header value was already seen before.

  When a message is routed within the exchange, it's checked against duplicates.
  If no duplicate is found, the message is routed and its deduplication header
  cached. If a TTL was set, the header is removed once expired.
  If the deduplication cache fills up, old elements will be removed
  to make space to new onces.

  This module implements the `rabbit_exchange_type` behaviour.

  """

  import Record, only: [defrecord: 2, extract: 2]

  require RabbitMQ.MessageDeduplicationPlugin.Cache
  require RabbitMQ.MessageDeduplicationPlugin.Common

  alias :rabbit_log, as: RabbitLog
  alias :rabbit_misc, as: RabbitMisc
  alias :rabbit_router, as: RabbitRouter
  alias :rabbit_exchange, as: RabbitExchange
  alias RabbitMQ.MessageDeduplicationPlugin.Common, as: Common
  alias RabbitMQ.MessageDeduplicationPlugin.Cache, as: Cache
  alias RabbitMQ.MessageDeduplicationPlugin.CacheManager, as: CacheManager

  @behaviour :rabbit_exchange_type

  Module.register_attribute __MODULE__,
    :rabbit_boot_step,
    accumulate: true, persist: true

  @rabbit_boot_step {__MODULE__,
                     [{:description, "exchange type x-message-deduplication"},
                      {:mfa, {:rabbit_registry, :register,
                              [:exchange, <<"x-message-deduplication">>,
                               __MODULE__]}},
                      {:requires, :rabbit_registry},
                      {:enables, :kernel_ready}]}

  defrecord :exchange, extract(
    :exchange, from_lib: "rabbit_common/include/rabbit.hrl")

  defrecord :delivery, extract(
    :delivery, from_lib: "rabbit_common/include/rabbit.hrl")

  defrecord :basic_message, extract(
    :basic_message, from_lib: "rabbit_common/include/rabbit.hrl")

  def description() do
    [
      {:name, <<"x-message-deduplication">>},
      {:description, <<"Message Deduplication Exchange.">>}
    ]
  end

  def serialise_events() do
    false
  end

  def route(exchange(name: name), delivery(message: msg = basic_message())) do
    if route?(name, msg) do
      RabbitRouter.match_routing_key(name, [:_])
    else
      []
    end
  end

  def validate(exchange(arguments: args)) do
    case List.keyfind(args, "x-cache-size", 0) do
      {"x-cache-size", _, val} when is_integer(val) and val > 0 -> :ok
      {"x-cache-size", :longstr, val} ->
        case Integer.parse(val, 10) do
          :error -> RabbitMisc.protocol_error(
                      :precondition_failed,
                      "Missing or invalid argument, \
                      'x-cache-size' must be an integer greater than 0", [])
          _ -> :ok
        end
      _ ->
        RabbitMisc.protocol_error(
          :precondition_failed,
          "Missing or invalid argument, \
          'x-cache-size' must be an integer greater than 0", [])
    end

    case List.keyfind(args, "x-cache-ttl", 0) do
      nil -> :ok
      {"x-cache-ttl", _, val} when is_integer(val) and val > 0 -> :ok
      {"x-cache-ttl", :longstr, val} ->
        case Integer.parse(val, 10) do
          :error -> RabbitMisc.protocol_error(
                      :precondition_failed,
                      "Invalid argument, \
                      'x-cache-ttl' must be an integer greater than 0", [])
          _ -> :ok
        end
      _ -> RabbitMisc.protocol_error(
             :precondition_failed,
             "Invalid argument, \
             'x-cache-ttl' must be an integer greater than 0", [])
    end

    case List.keyfind(args, "x-cache-persistence", 0) do
      nil -> :ok
      {"x-cache-persistence", :longstr, "disk"} -> :ok
      {"x-cache-persistence", :longstr, "memory"} -> :ok
      _ -> RabbitMisc.protocol_error(
             :precondition_failed,
             "Invalid argument, \
             'x-cache-persistence' must be either 'disk' or 'memory'", [])
    end
  end

  def validate_binding(_ex, _bs) do
    :ok
  end

  def create(:transaction, exchange(name: name, arguments: args)) do
    cache = Common.cache_name(name)
    options = [size: Common.rabbit_argument(
                 args, "x-cache-size", type: :number),
               ttl: Common.rabbit_argument(
                 args, "x-cache-ttl", type: :number),
               persistence: Common.rabbit_argument(
                 args, "x-cache-persistence", type: :atom, default: "memory")]

    RabbitLog.debug(
      "Starting exchange deduplication cache ~s with options ~p~n",
      [cache, options])

    CacheManager.create(cache, options)
  end

  def create(_tx, _ex) do
    :ok
  end

  def delete(:transaction, exchange(name: name), _bs) do
    name |> Common.cache_name() |> CacheManager.destroy()
  end

  def delete(:none, _ex, _bs) do
    :ok
  end

  def policy_changed(_x1, _x2) do
    :ok
  end

  def add_binding(_tx, _ex, _bs) do
    :ok
  end

  def remove_bindings(_tx, _ex, _bs) do
    :ok
  end

  def assert_args_equivalence(exchange, args) do
    RabbitExchange.assert_args_equivalence(exchange, args)
  end

  def info(exchange) do
    info(exchange, [:cache_info])
  end

  def info(exchange(name: name), [:cache_info]) do
    [cache_info: name |> Common.cache_name() |> Cache.info()]
  end

  def info(_ex, _it) do
    []
  end

  # Utility functions

  # Whether to route the message or not.
  defp route?(exchange_name, message) do
    ttl = Common.message_header(message, "x-cache-ttl")
    not Common.duplicate?(exchange_name, message, ttl)
  end
end
