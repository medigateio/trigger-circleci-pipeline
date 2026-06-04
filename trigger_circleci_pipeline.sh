#!/usr/bin/env bash

set -e

CIRCLECI_API_BASE="https://circleci.com/api/v2"
CIRCLECI_PROJECT_API_BASE="${CIRCLECI_API_BASE}/project/github/${GITHUB_REPOSITORY}"
CIRCLE_WORKFLOW_URL_BASE="https://circleci.com/workflow-run"
MAX_PIPELINE_CREATION_RETRIES=10

branch="${BRANCH_REF#refs/heads/}"

WORKFLOW_KWARGS="${WORKFLOW_KWARGS-"{}"}"

is_valid_json() {
    jq -e . >/dev/null 2>&1 <<< "${1}"
}

print_circleci_response_error() {
    local request_description="${1}"
    local http_code="${2}"
    local response_body="${3}"

    echo "CircleCI API request failed for ${request_description} (HTTP ${http_code})"

    if is_valid_json "${response_body}"; then
        error_message=$(jq -r '.message // .error // empty' <<< "${response_body}")
        if [ -n "${error_message}" ]; then
            echo "${error_message}"
        else
            echo "${response_body}" | jq .
        fi
        return
    fi

    echo "CircleCI returned a non-JSON response:"
    echo "${response_body}"
}

circleci_request() {
    local method="${1}"
    local url="${2}"
    local request_data="${3-}"
    local response_file
    local response_body
    local http_code
    local curl_exit_code
    local -a curl_args=(
        -sS
        --location
        --retry 3
        --retry-delay 2
        --retry-all-errors
        -X "${method}"
        -H "Circle-Token: ${CIRCLECI_USER_PERSONAL_API_TOKEN}"
        --output "${response_file}"
        --write-out "%{http_code}"
    )

    response_file=$(mktemp)

    if [ "${method}" = "POST" ]; then
        curl_args+=(
            -H 'Content-type: application/json'
            -H "x-attribution-login: ${GITHUB_ACTOR}"
            -H "x-attribution-actor-id: medigate-ci-functions"
            -d "${request_data}"
        )
    fi

    http_code=$(curl "${curl_args[@]}" "${url}") || {
        curl_exit_code=$?
        response_body=$(< "${response_file}")
        rm -f "${response_file}"
        echo "Failed to call CircleCI API for ${method} ${url} (curl exit code ${curl_exit_code})"
        if [ -n "${response_body}" ]; then
            echo "${response_body}"
        fi
        exit 5
    }

    response_body=$(< "${response_file}")
    rm -f "${response_file}"

    if ! is_valid_json "${response_body}"; then
        echo "CircleCI returned a non-JSON response for ${method} ${url} (HTTP ${http_code})"
        if [ -n "${response_body}" ]; then
            echo "${response_body}"
        fi
        exit 5
    fi

    if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
        print_circleci_response_error "${method} ${url}" "${http_code}" "${response_body}"
        exit 5
    fi

    printf '%s' "${response_body}"
}

if [ -z "${TRIGGERED_WORKFLOW}" ]; then
    echo "No triggered workflow passed"
    exit 1
fi

if ! is_valid_json "${WORKFLOW_KWARGS}"; then
    echo "Workflow kwargs should be valid JSON"
    exit 1
fi

if [ "$(jq -r 'has("triggered_workflow")' <<< "${WORKFLOW_KWARGS}")" != "false" ]; then
    echo "Workflow kwargs should not have an arg named 'triggered_workflow'"
    exit 1
fi

request_data=$(
    jq \
        --arg triggered_workflow "${TRIGGERED_WORKFLOW}" \
        --arg branch "${branch}" \
        '{"branch": $branch, "parameters": (. += {"triggered_workflow": $triggered_workflow})}' <<< "${WORKFLOW_KWARGS}"
)

trigger_pipeline_response=$(
    circleci_request POST "${CIRCLECI_PROJECT_API_BASE}/pipeline" "${request_data}"
)

error_message=$(jq -r '.message' <<< "${trigger_pipeline_response}")

if [ "${error_message}" != "null" ]; then
    echo "Error while trying to trigger workflow \"${TRIGGERED_WORKFLOW}\" on branch \"${branch}\":"
    echo "${error_message}"
    exit 1
fi

pipeline_number=$(jq -r '.number' <<< "${trigger_pipeline_response}")
pipeline_id=$(jq -r '.id' <<< "${trigger_pipeline_response}")
pipeline_state=$(jq -r '.state' <<< "${trigger_pipeline_response}")

echo "Triggered workflow \"${TRIGGERED_WORKFLOW}\" on branch \"${branch}\":"
echo "Pipeline #${pipeline_number} (${pipeline_id}) in state \"${pipeline_state}\""

if [ "${pipeline_state}" = "errored" ]; then
    echo "Failed to create pipeline"
    exit 2
elif [ "${pipeline_state}" != "created" ]; then
    n=1
    # Retrying to check the pipeline state before timing out
    until [ "$n" -gt "${MAX_PIPELINE_CREATION_RETRIES}" ]
    do
        echo "Re-checking pipeline state (retry #${n})"
        status_response=$(
            circleci_request GET "${CIRCLECI_API_BASE}/pipeline/${pipeline_id}" | jq -r '.state'
        )

        if [ "${status_response}" = "errored" ]; then
            echo "Failed to create pipeline"
            exit 3
        elif [ "${status_response}" = "created" ]; then
            echo "Created pipeline"
            break
        fi

        n=$((n+1))
        sleep 5
    done

    if [ "${n}" -gt "${MAX_PIPELINE_CREATION_RETRIES}" ]; then
      # Time out after the configured retry count
      echo "Timed out waiting for pipeline creation"
      exit 4
    fi
fi

pipeline_workflows_response=$(
    circleci_request GET "${CIRCLECI_API_BASE}/pipeline/${pipeline_id}/workflow" | jq -r '.items[] | .id'
)

echo "Workflow URL(s):"
for workflow_id in $pipeline_workflows_response
do
  echo "${CIRCLE_WORKFLOW_URL_BASE}/${workflow_id}"
done

if [ "${SHOULD_WAIT}" = "true" ]; then
    echo "Waiting for workflow to finish"
    for workflow_id in $pipeline_workflows_response
    do
        while :
        do
            sleep 10
            result=$(circleci_request GET "${CIRCLECI_API_BASE}/workflow/${workflow_id}" | jq ".status")

            case $result in
            \"running\")
                ;;
            \"success\")
                echo "Succeeded"
                exit 0
                ;;
            *) # \"not_run\" | \"failed\" | \"error\" | \"failing\" | \"on_hold\" | \"canceled\" | \"blocked\"
                echo "Failed: $result"
                exit 1
                ;;
            esac
        done
    done
fi
