#!/usr/bin/env bash

function cleanup_mem0() {
    docker stop mem0-dashboard postgres 2>/dev/null || true
    docker stop mem0 2>/dev/null || true
    docker stop postgres 2>/dev/null || true

    docker rm mem0-dashboard mem0 postgres 2>/dev/null || true
    docker network rm mem0_network 2>/dev/null || true
}

function cleanup_opensearch {
    docker stop opensearch-single opensearch-single-dashboards 2>/dev/null || true
    docker rm opensearch-single opensearch-single-dashboards 2>/dev/null || true

    docker network rm opensearch-net 2>/dev/null || true
}

cleanup_mem0
cleanup_opensearch
