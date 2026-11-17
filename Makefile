SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

APP ?= blob-polling
COUNT ?= 1
BLOB_PREFIX ?=
# Options passed to a scenario, e.g. make scenario-02 SCENARIO_ARGS="--count 50" (see the script's --help).
SCENARIO_ARGS ?=

.PHONY: upload-test-blob measure-latency replicas logs integration-test lint validate-k8s scenarios \
	scenario-01 scenario-02 scenario-03 scenario-04 scenario-05 scenario-06 scenario-07 scenario-08 scenario-09 scenario-10

upload-test-blob:
	bash ./scripts/upload-test-blob.sh "$(APP)" "$(COUNT)"

measure-latency:
	bash ./scripts/measure-latency.sh "$(APP)" "$(BLOB_PREFIX)"

replicas:
	bash ./scripts/replicas.sh

logs:
	bash ./scripts/logs.sh "$(APP)"

integration-test:
	bash ./scripts/integration-test.sh

# The quick scenarios; the others change the cluster or take long (see their --help).
scenarios: scenario-01 scenario-02 scenario-04 scenario-08

scenario-01:
	bash ./scripts/scenarios/01-one-blob.sh $(SCENARIO_ARGS)

scenario-02:
	bash ./scripts/scenarios/02-concurrent-blobs.sh $(SCENARIO_ARGS)

scenario-03:
	bash ./scripts/scenarios/03-large-batch-scale.sh $(SCENARIO_ARGS)

scenario-04:
	bash ./scripts/scenarios/04-duplicate-delivery.sh $(SCENARIO_ARGS)

scenario-05:
	bash ./scripts/scenarios/05-pod-restart.sh $(SCENARIO_ARGS)

scenario-06:
	bash ./scripts/scenarios/06-rolling-deployment.sh $(SCENARIO_ARGS)

scenario-07:
	bash ./scripts/scenarios/07-dependency-unavailable.sh $(SCENARIO_ARGS)

scenario-08:
	bash ./scripts/scenarios/08-poison-and-dead-letter.sh $(SCENARIO_ARGS)

scenario-09:
	bash ./scripts/scenarios/09-historical-blobs.sh $(SCENARIO_ARGS)

scenario-10:
	bash ./scripts/scenarios/10-host-id-stability.sh $(SCENARIO_ARGS)

lint:
	shellcheck -x scripts/*.sh scripts/scenarios/*.sh infra/hooks/*/*.sh

validate-k8s:
	export BLOB_POLLING_CLIENT_ID=00000000-0000-0000-0000-000000000001; \
	export QUEUE_TRIGGERED_CLIENT_ID=00000000-0000-0000-0000-000000000002; \
	export SERVICEBUS_TRIGGERED_CLIENT_ID=00000000-0000-0000-0000-000000000003; \
	export SERVICE_BUS_NAMESPACE=example-bus; \
	export UPLOADS_ACCOUNT_1=uploadaccount1; \
	export UPLOADS_ACCOUNT_2=uploadaccount2; \
	export UPLOADS_ACCOUNT_3=uploadaccount3; \
	export HOST_ACCOUNT_1=hostaccount1; \
	export HOST_ACCOUNT_2=hostaccount2; \
	export HOST_ACCOUNT_3=hostaccount3; \
	export BLOB_POLLING_REPLICAS=2; \
	export KEDA_MIN_REPLICAS=1; \
	export KEDA_MAX_REPLICAS=10; \
	export KEDA_MESSAGES_PER_REPLICA=5; \
	export APPLICATIONINSIGHTS_CONNECTION_STRING='InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.com/'; \
	export SERVICE_BLOB_POLLING_IMAGE_NAME=example.azurecr.io/blob-polling:latest; \
	export SERVICE_QUEUE_TRIGGERED_IMAGE_NAME=example.azurecr.io/queue-triggered:latest; \
	export SERVICE_SERVICEBUS_TRIGGERED_IMAGE_NAME=example.azurecr.io/servicebus-triggered:latest; \
	for manifest in k8s/*.yaml k8s/*/*.yaml; do \
	  printf '%s\n' '---'; \
	  envsubst < "$$manifest"; \
	done | \
	  kubeconform -ignore-missing-schemas -
