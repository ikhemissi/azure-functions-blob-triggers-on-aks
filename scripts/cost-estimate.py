#!/usr/bin/env python3
"""Monthly cost of each trigger's own resources and operations, from Azure retail prices (Q13).

Prints Markdown tables for docs/experiments/08-costs.md. Only what differs between the three ways of triggering is
counted; what every option needs the same way (the cluster's nodes, the apps' own storage, Application Insights) is
listed once, with the private networking overhead. Prices are list prices without discounts or taxes.

Usage: python3 scripts/cost-estimate.py
"""

HOURS_PER_MONTH = 730

# EUR, francecentral (or the global meter where the service has one), pay-as-you-go retail prices read on 2026-11-19
# from https://prices.azure.com/api/retail/prices. Read them again before relying on the result.
PRICES = {
    "service_bus_standard_base_per_month": 8.9771,
    "service_bus_standard_operations_included": 13_000_000,
    "service_bus_standard_per_million_operations": 0.7182,  # from 13 to 100 million operations
    "service_bus_premium_messaging_unit_per_hour": 0.8326,
    "event_grid_operations_included": 100_000,
    "event_grid_per_million_operations": 0.539,
    "queue_v2_per_10k_operations": 0.0036,
    "blob_list_per_10k_operations": 0.053,
    "blob_write_per_10k_operations": 0.053,
    "private_endpoint_per_hour": 0.009,
    "registry_basic_per_day": 0.1496,
    "registry_premium_per_day": 1.4961,
    "node_d2als_v7_per_hour": 0.0847,
    "bastion_standard_per_hour": 0.2603,
    "nat_gateway_per_hour": 0.0404,
    "static_public_ip_per_hour": 0.0045,
}

# How each trigger uses the services, per blob and over time (docs/DESIGN.md, experiments 02 and 03).
SCANS_PER_MONTH = HOURS_PER_MONTH * 3600 // 10  # the polling trigger lists the container every 10 s
LIST_CALLS_PER_SCAN = 1  # one page of up to 5,000 blobs: a container with more blobs needs more calls per scan
QUEUE_OPERATIONS_PER_MESSAGE = 3  # put, get, delete
SERVICE_BUS_OPERATIONS_PER_MESSAGE = 3  # send, receive, complete
POLLS_PER_MONTH_DEFAULT = HOURS_PER_MONTH * 60  # an idle queue polled once a minute (maxPollingInterval default)
POLLS_PER_MONTH_TUNED = HOURS_PER_MONTH * 3600 // 2  # maxPollingInterval at 2 s (experiment 03)
PRIVATE_ENDPOINTS_PER_APP = 5  # host account blob, queue and table; upload account blob and queue (or Service Bus)
SPIKE_PRIVATE_ENDPOINTS = 16  # the three apps' accounts, the Service Bus namespace and the registry (experiment 05)

BLOBS_PER_MONTH = [10_000, 1_000_000, 10_000_000]


def per_10k(operations: float, price: float) -> float:
    return operations / 10_000 * price


def event_grid(blobs: int) -> float:
    billable = max(0, blobs - PRICES["event_grid_operations_included"])
    return billable / 1_000_000 * PRICES["event_grid_per_million_operations"]


def polling_trigger(blobs: int) -> float:
    scans = per_10k(SCANS_PER_MONTH * LIST_CALLS_PER_SCAN, PRICES["blob_list_per_10k_operations"])
    receipts = per_10k(blobs, PRICES["blob_write_per_10k_operations"])
    internal_queue = per_10k(blobs * QUEUE_OPERATIONS_PER_MESSAGE, PRICES["queue_v2_per_10k_operations"])
    return scans + receipts + internal_queue


def storage_queue_trigger(blobs: int, polls_per_month: int) -> float:
    messages = per_10k(blobs * QUEUE_OPERATIONS_PER_MESSAGE, PRICES["queue_v2_per_10k_operations"])
    idle_polls = per_10k(polls_per_month, PRICES["queue_v2_per_10k_operations"])
    return event_grid(blobs) + messages + idle_polls


def service_bus_trigger(blobs: int, private: bool) -> float:
    if private:
        # Private endpoints need the Premium tier, whose messaging unit includes the operations.
        namespace = PRICES["service_bus_premium_messaging_unit_per_hour"] * HOURS_PER_MONTH
    else:
        operations = blobs * SERVICE_BUS_OPERATIONS_PER_MESSAGE
        billable = max(0, operations - PRICES["service_bus_standard_operations_included"])
        namespace = PRICES["service_bus_standard_base_per_month"]
        namespace += billable / 1_000_000 * PRICES["service_bus_standard_per_million_operations"]
    return event_grid(blobs) + namespace


def euros(amount: float) -> str:
    return f"€{amount:,.2f}"


def print_trigger_table() -> None:
    header = " | ".join(f"{blobs:,} blobs" for blobs in BLOBS_PER_MONTH)
    print(f"| Trigger, network | {header} |")
    print("|---|" + "---|" * len(BLOBS_PER_MONTH))
    rows = [
        ("Polling Blob trigger, public or private", lambda b: polling_trigger(b)),
        ("Storage queue, default polling", lambda b: storage_queue_trigger(b, POLLS_PER_MONTH_DEFAULT)),
        ("Storage queue, `maxPollingInterval` 2 s", lambda b: storage_queue_trigger(b, POLLS_PER_MONTH_TUNED)),
        ("Service Bus Standard, public", lambda b: service_bus_trigger(b, private=False)),
        ("Service Bus Premium (1 unit), private", lambda b: service_bus_trigger(b, private=True)),
    ]
    for name, cost in rows:
        print(f"| {name} | " + " | ".join(euros(cost(blobs)) for blobs in BLOBS_PER_MONTH) + " |")


def print_shared_table() -> None:
    month = HOURS_PER_MONTH
    rows = [
        ("Two D2als_v7 nodes (all options, both phases)", 2 * PRICES["node_d2als_v7_per_hour"] * month),
        (
            f"Private endpoints, {PRIVATE_ENDPOINTS_PER_APP} per app (private)",
            PRIVATE_ENDPOINTS_PER_APP * PRICES["private_endpoint_per_hour"] * month,
        ),
        (
            "Registry Premium instead of Basic (private)",
            (PRICES["registry_premium_per_day"] - PRICES["registry_basic_per_day"]) * month / 24,
        ),
        ("Bastion's two static public IPs (private)", 2 * PRICES["static_public_ip_per_hour"] * month),
        (
            "One working hour: Bastion Standard, NAT Gateway, jumpbox (private)",
            PRICES["bastion_standard_per_hour"] + PRICES["nat_gateway_per_hour"] + PRICES["node_d2als_v7_per_hour"],
        ),
    ]
    print("| Shared item | Cost |")
    print("|---|---|")
    for name, cost in rows:
        unit = "" if name.startswith("One working hour") else " a month"
        print(f"| {name} | {euros(cost)}{unit} |")


def print_spike_table() -> None:
    """The spike's environment per hour: the three apps side by side, without usage-based items (storage, logs)."""
    phase_1 = (
        2 * PRICES["node_d2als_v7_per_hour"]
        + PRICES["service_bus_standard_base_per_month"] / HOURS_PER_MONTH
        + PRICES["registry_basic_per_day"] / 24
    )
    phase_2 = (
        2 * PRICES["node_d2als_v7_per_hour"]
        + PRICES["service_bus_premium_messaging_unit_per_hour"]
        + PRICES["registry_premium_per_day"] / 24
        + SPIKE_PRIVATE_ENDPOINTS * PRICES["private_endpoint_per_hour"]
        + 2 * PRICES["static_public_ip_per_hour"]
    )
    print("| The spike's environment | Per hour | Per day |")
    print("|---|---|---|")
    print(f"| Phase 1 | {euros(phase_1)} | {euros(phase_1 * 24)} |")
    print(f"| Phase 2, no Bastion session | {euros(phase_2)} | {euros(phase_2 * 24)} |")


if __name__ == "__main__":
    print_trigger_table()
    print()
    print_shared_table()
    print()
    print_spike_table()
