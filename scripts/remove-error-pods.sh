#!/usr/bin/env bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_NAME=$(basename "$0")
DRY_RUN=false
ALL_NAMESPACES=true
NAMESPACE=""
FORCE=false
VERBOSE=false

# Error and completed states to clean up
ERROR_STATES=("Error" "Failed" "CrashLoopBackOff" "ImagePullBackOff" "ErrImagePull" "InvalidImageName" "CreateContainerConfigError" "CreateContainerError" "Init:Error" "Init:CrashLoopBackOff")
COMPLETED_STATES=("Completed" "Succeeded")

# Help function
show_help() {
    cat << EOF
${SCRIPT_NAME} - Clean up Kubernetes pods in error or completed states

USAGE:
    ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
    -n, --namespace NAMESPACE   Target specific namespace (default: all namespaces)
    -d, --dry-run              Show what would be deleted without actually deleting
    -f, --force                Skip confirmation prompts
    -v, --verbose              Enable verbose output
    -h, --help                 Show this help message

EXAMPLES:
    ${SCRIPT_NAME}                          # Clean up all namespaces with confirmation
    ${SCRIPT_NAME} -n kube-system          # Clean up only kube-system namespace
    ${SCRIPT_NAME} --dry-run               # Preview what would be deleted
    ${SCRIPT_NAME} -f                      # Delete without confirmation
    ${SCRIPT_NAME} -n flux-system -v -f    # Clean flux-system namespace, verbose, no confirmation

STATES CLEANED UP:
    Error States: ${ERROR_STATES[*]}
    Completed States: ${COMPLETED_STATES[*]}
EOF
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Check dependencies
check_dependencies() {
    local deps=("kubectl" "jq")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -ne 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install the missing dependencies and try again."
        exit 1
    fi
}

# Check kubectl connection
check_kubectl_connection() {
    log_verbose "Checking kubectl connection..."
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi
    log_verbose "kubectl connection successful"
}

# Get pods in error states
get_error_pods() {
    local namespace_arg=""
    if [[ "$ALL_NAMESPACES" == false ]]; then
        namespace_arg="-n $NAMESPACE"
    else
        namespace_arg="--all-namespaces"
    fi

    local error_filter=""
    for i in "${!ERROR_STATES[@]}"; do
        if [[ $i -eq 0 ]]; then
            error_filter="status.phase==\"${ERROR_STATES[$i]}\""
        else
            error_filter="$error_filter or status.phase==\"${ERROR_STATES[$i]}\""
        fi
    done

    # Also check for pods with error conditions
    local condition_filter=""
    for state in "${ERROR_STATES[@]}"; do
        if [[ -n "$condition_filter" ]]; then
            condition_filter="$condition_filter or "
        fi
        condition_filter="${condition_filter}status.containerStatuses[].state.waiting.reason==\"$state\""
    done

    if [[ -n "$condition_filter" ]]; then
        error_filter="$error_filter or $condition_filter"
    fi

    kubectl get pods $namespace_arg -o json | \
        jq -r --argjson error_states "$(printf '%s\n' "${ERROR_STATES[@]}" | jq -R . | jq -s .)" \
        '.items[] | select(
            (.status.phase as $phase | $error_states | index($phase)) or
            (.status.containerStatuses[]? | select(.state.waiting.reason as $reason | $error_states | index($reason))) or
            (.status.initContainerStatuses[]? | select(.state.waiting.reason as $reason | $error_states | index($reason)))
        ) | "\(.metadata.namespace) \(.metadata.name) \(.status.phase // (.status.containerStatuses[]? | select(.state.waiting) | .state.waiting.reason) // (.status.initContainerStatuses[]? | select(.state.waiting) | .state.waiting.reason))"' 2>/dev/null || true
}

# Get pods in completed states
get_completed_pods() {
    local namespace_arg=""
    if [[ "$ALL_NAMESPACES" == false ]]; then
        namespace_arg="-n $NAMESPACE"
    else
        namespace_arg="--all-namespaces"
    fi

    kubectl get pods $namespace_arg -o json | \
        jq -r --argjson completed_states "$(printf '%s\n' "${COMPLETED_STATES[@]}" | jq -R . | jq -s .)" \
        '.items[] | select(.status.phase as $phase | $completed_states | index($phase)) | "\(.metadata.namespace) \(.metadata.name) \(.status.phase)"' 2>/dev/null || true
}

# Display pods to be deleted
display_pods() {
    local pods=("$@")
    if [[ ${#pods[@]} -eq 0 ]]; then
        log_info "No pods found in error or completed states."
        return 0
    fi

    echo
    log_info "Found ${#pods[@]} pod(s) to clean up:"
    echo
    printf "%-20s %-50s %-20s\n" "NAMESPACE" "POD NAME" "STATUS"
    printf "%-20s %-50s %-20s\n" "----------" "--------" "------"

    for pod_info in "${pods[@]}"; do
        read -r namespace name status <<< "$pod_info"
        printf "%-20s %-50s %-20s\n" "$namespace" "$name" "$status"
    done
    echo
}

# Delete pods
delete_pods() {
    local pods=("$@")
    local success_count=0
    local error_count=0

    set +e
    log_info "Deleting ${#pods[@]} pod(s)..."
    for pod_info in "${pods[@]}"; do
        read -r namespace name status <<< "$pod_info"
        log_verbose "Deleting pod $name in namespace $namespace (status: $status)"

        kubectl delete pod "$name" -n "$namespace" --ignore-not-found=true &>/dev/null
        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_success "Deleted pod $name in namespace $namespace"
            ((success_count++))
        else
            log_error "Failed to delete pod $name in namespace $namespace"
            ((error_count++))
        fi

    done

    set -e

    echo
    log_info "Cleanup completed: $success_count successful, $error_count failed"
}


# Confirm deletion
confirm_deletion() {
    local pod_count=$1

    if [[ "$FORCE" == true ]]; then
        return 0
    fi

    echo
    read -p "Are you sure you want to delete these $pod_count pod(s)? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Operation cancelled by user."
        exit 0
    fi
}

# Main function
main() {
    log_info "Starting Kubernetes pod cleanup..."

    # Check dependencies and connection
    check_dependencies
    check_kubectl_connection

    # Get pods in error and completed states
    log_verbose "Searching for pods in error states..."
    local error_pods=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && error_pods+=("$line")
    done < <(get_error_pods)

    log_verbose "Searching for pods in completed states..."
    local completed_pods=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && completed_pods+=("$line")
    done < <(get_completed_pods)

    # Combine all pods to delete
    local all_pods=("${error_pods[@]}" "${completed_pods[@]}")

    # Display pods
    display_pods "${all_pods[@]}"

    if [[ ${#all_pods[@]} -eq 0 ]]; then
        exit 0
    fi

    # Dry run mode
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN MODE: No pods were actually deleted."
        exit 0
    fi

    # Confirm deletion
    confirm_deletion ${#all_pods[@]}

    # Delete pods
    log_info "Deleting pods..."
    delete_pods "${all_pods[@]}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--namespace)
            NAMESPACE="$2"
            ALL_NAMESPACES=false
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate namespace if specified
if [[ "$ALL_NAMESPACES" == false ]] && [[ -n "$NAMESPACE" ]]; then
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist."
        exit 1
    fi
fi

# Run main function
main
