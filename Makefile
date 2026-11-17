SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

APP ?= blob-polling
COUNT ?= 1
BLOB_PREFIX ?=

.PHONY: upload-test-blob measure-latency replicas logs integration-test lint validate-k8s

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

lint:
	shellcheck -x scripts/*.sh infra/hooks/*/*.sh

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
