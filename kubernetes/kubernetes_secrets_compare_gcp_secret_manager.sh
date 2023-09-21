#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2023-07-26 00:38:43 +0100 (Wed, 26 Jul 2023)
#
#  https://github.com/HariSekhon/DevOps-Bash-tools
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help steer this or other code I publish
#
#  https://www.linkedin.com/in/HariSekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090,SC1091
. "$srcdir/lib/utils.sh"

# shellcheck disable=SC1090,SC1091
. "$srcdir/lib/kubernetes.sh"

# shellcheck disable=SC2034,SC2154
usage_description="
Compares each Kubernetes secret to GCP Secret Manager

Checks

- that the kubernetes secret exists in GCP Secret Manager
- that the kubernetes secret value matches the value of the latest version in GCP Secret Manager

Useful to verify before enabling pulling external secrets from GCP Secret Manager

See kubernetes_secrets_to_external_secrets_gcp.sh to quickly migrate all your secrets to external secrets

Use kubectl_secrets_download.sh to take a backup of existing kubernetes secrets first


Requires kubectl and GCloud SDK to both be in the \$PATH and configured
"

# used by usage() in lib/utils.sh
# shellcheck disable=SC2034
usage_args="[<namespace> <context>]"

help_usage "$@"

max_args 2 "$@"

check_bin kubectl
check_bin gcloud

namespace="${1:-}"
context="${2:-}"

kube_config_isolate

if [ -n "$context" ]; then
    kube_context "$context"
fi
if [ -n "$namespace" ]; then
    kube_namespace "$namespace"
fi

if [ -z "${namespace:-}" ]; then
    namespace="$(kube_current_namespace)"
fi

secrets="$(
    kubectl get secrets |
    grep -v '^NAME[[:space:]]' |
    awk '{print $1}'
)"

max_len=0
while read -r secret; do
    if [ "${#secret}" -gt "$max_len" ]; then
        max_len="${#secret}"
    fi
done <<< "$secrets"

exitcode=0

check_secret(){
    local secret="$1"
    local k8s_secret_value
    local gcp_secret_value
    printf "Kubernetes secret %-${max_len}s => " "$secret"

    # if the secret has a dash in it, then you need to quote it whether .data."$secret" or .data["$secret"]
    k8s_secret_value="$(kubectl get secret "$secret" -o json | jq -r ".data[\"$secret\"]" | base64 --decode)"

    if [ -z "$k8s_secret_value" ]; then
        echo "FAILED_TO_GET_K8s_SECRET"
        exitcode=1
    fi

    secret_json="$(kubectl get secret "$secret" -o json)"
    secret_type="$(jq -r '.type' <<< "$secret_json")"
    if [ "$secret_type" = "kubernetes.io/service-account-token" ]; then
        echo "SKIP_K8s_SERVICE_ACCOUNT"
        return
    fi
    if [ "$secret_type" = "kubernetes.io/tls" ]; then
        tls_cert_manager_issuer="$(jq -r '.metadata.annotations."cert-manager.io/issuer-name"' <<< "$secret_json")"
        if [ -n "$tls_cert_manager_issuer" ]; then
            echo "SKIP_TLS_CERT_MANAGER"
            return
        fi
    fi

    if ! gcloud secrets list --format='value(name)' | grep -Fxq "$secret"; then
        echo "MISSING_ON_GCP"
        exitcode=1
    else
        gcp_secret_value="$("$srcdir/../gcp/gcp_secret_get.sh" "$secret")"
        # if it's GCP service account key
        if grep -Fq '"type": "service_account"' <<< "$gcp_secret_value"; then
            if [ -n "$(diff -w <(echo "$gcp_secret_value") <(echo "$k8s_secret_value") )" ]; then
                echo "MISMATCHED_GCP_SERVICE_ACCOUNT_VALUE"
                exitcode=1
            else
                echo "OK_GCP_SERVICE_ACCOUNT_VALUE"
            fi
        elif [ "$gcp_secret_value" = "$k8s_secret_value" ]; then
            echo "OK_GCP_VALUE_MATCHES"
        else
            echo "MISMATCHED_GCP_VALUE"
            exitcode=1
        fi
    fi
}

while read -r secret; do
    check_secret "$secret"
done <<< "$secrets"

exit $exitcode
