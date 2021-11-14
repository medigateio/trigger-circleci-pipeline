#!/usr/bin/env bash

set -e

CIRCLECI_API_BASE="https://circleci.com/api/v2"
CIRCLECI_PROJECT_API_BASE="${CIRCLECI_API_BASE}/project/github/${GITHUB_REPOSITORY}"
CIRCLE_WORKFLOW_URL_BASE="https://circleci.com/workflow-run"

branch="${GITHUB_REF#refs/heads/}"
workflow_to_trigger=$1

trigger_pipeline_response=$(
    curl -sSX POST \
        -H 'Content-type: application/json' \
        -H "Circle-Token: ${CIRCLECI_USER_PERSONAL_API_TOKEN}" \
        -H "x-attribution-login: ${GITHUB_ACTOR}" \
        -H "x-attribution-actor-id: medigate-ci-functions" \
        -d "{
          \"branch\": \"${branch}\",
          \"parameters\": {
            \"triggered_workflow\": \"${workflow_to_trigger}\"
          }
        }" \
        "${CIRCLECI_PROJECT_API_BASE}/pipeline"
)

error_message=$(jq -r '.message' <<< "${trigger_pipeline_response}")

if [ "${error_message}" != "null" ]; then
  echo "Error while trying to trigger workflow \"${workflow_to_trigger}\" on branch \"${branch}\":"
  echo "${error_message}"
  exit 1
fi

pipeline_number=$(jq -r '.number' <<< "${trigger_pipeline_response}")
pipeline_id=$(jq -r '.id' <<< "${trigger_pipeline_response}")
pipeline_state=$(jq -r '.state' <<< "${trigger_pipeline_response}")

echo "Triggered workflow \"${workflow_to_trigger}\" on branch \"${branch}\":"
echo "Pipeline #${pipeline_number} (${pipeline_id}) in state \"${pipeline_state}\""

if [ "${pipeline_state}" = "errored" ]; then
    echo "Failed to create pipeline"
    exit 2
elif [ "${pipeline_state}" != "created" ]; then
    n=1
    # Retrying to check the pipeline state 5 times
    until [ "$n" -ge 5 ]
    do
        echo "Re-checking pipeline state (retry #${n})"
        status_response=$(
            curl -sSX GET \
                -H "Circle-Token: ${CIRCLECI_USER_PERSONAL_API_TOKEN}" \
                "${CIRCLECI_API_BASE}/pipeline/${pipeline_id}" \
            | jq -r '.state'
        )

        if [ "${status_response}" = "errored" ]; then
            echo "Failed to create pipeline"
            return 3
        elif [ "${status_response}" = "created" ]; then
            echo "Created pipeline"
            break
        fi

        n=$((n+1))
        sleep 3
    done

    if [ "${n}" = 5 ]; then
      # Time out after 5 retries
      echo "Timed out waiting for pipeline creation"
      return 4
    fi
fi

pipeline_workflows_response=$(
    curl -sSX GET \
        -H "Circle-Token: ${CIRCLECI_USER_PERSONAL_API_TOKEN}" \
        "${CIRCLECI_API_BASE}/pipeline/${pipeline_id}/workflow" \
    | jq -r '.items[] | .id'
)

echo "Workflow URL(s):"
for workflow_id in $pipeline_workflows_response
do
  echo "${CIRCLE_WORKFLOW_URL_BASE}/${workflow_id}"
done
