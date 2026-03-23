# Dashboard Design Reference

Quick reference for designing effective Grafana dashboards.

## Design Principles

### Information Hierarchy

Arrange panels top-to-bottom by importance:

1. **Overview** -- Stat panels showing critical numbers (error rate, uptime, request rate)
2. **Trends** -- Time series graphs showing key metrics over time
3. **Details** -- Tables, heatmaps, and logs for investigation

### RED Method (for services)

| Signal   | What to measure         | Example metric                              |
|----------|-------------------------|---------------------------------------------|
| Rate     | Requests per second     | `sum(rate(http_requests_total[5m]))`        |
| Errors   | Error rate / percentage | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))` |
| Duration | Latency / response time | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))` |

### USE Method (for resources)

| Signal      | What to measure           | Example metric                                  |
|-------------|---------------------------|-------------------------------------------------|
| Utilization | % time resource is busy   | `100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100` |
| Saturation  | Queue length / wait time  | `node_load1` or swap usage                      |
| Errors      | Error count               | `node_disk_io_errors_total`                     |

## Common Dashboard Patterns

### Infrastructure Monitoring

Key panels: CPU utilization per node, memory usage per node, disk I/O, network traffic, pod count by namespace, node status.

### Application Monitoring

Key panels: request rate, error rate (%), response time percentiles (P50/P95/P99), active users/sessions, cache hit rate, queue length.

### Database Monitoring

Key panels: queries per second, connection pool usage, query latency (P50/P95/P99), active connections, database size, replication lag, slow queries.

### Business KPIs

Key panels: revenue/transactions per minute, user sign-ups, conversion funnel, active users, SLA compliance percentage.

## Panel Type Selection Guide

| Use Case                        | Recommended Panel Type |
|---------------------------------|------------------------|
| Single current value            | Stat                   |
| Metric over time                | Time series            |
| Tabular data or instant queries | Table                  |
| Value against a range/limit     | Gauge                  |
| Distribution over time          | Heatmap                |
| Comparing values across items   | Bar gauge              |
| Static documentation or links   | Text                   |
| Active alerts summary           | Alert list             |
| Log stream exploration          | Logs                   |
| Distributed trace view          | Traces                 |
| Custom spatial layouts          | Canvas                 |
| Geographic data                 | Geomap                 |

## Layout Guidelines

### Grid System

Grafana uses a 24-column grid. Standard panel widths:

| Width   | Columns | Typical use                  |
|---------|---------|------------------------------|
| Full    | 24      | Primary time series, heatmap |
| Half    | 12      | Side-by-side comparisons     |
| Third   | 8       | Stat panels, gauges          |
| Quarter | 6       | Stat panels in a row of four |

### Organization

- Place critical metrics (stat panels) in the top row.
- Use collapsible rows to group related panels by category.
- Keep panel heights consistent within each row (common: 8 units for graphs, 4 units for stats).
- Order rows from most critical to most detailed, top to bottom.

## Best Practices

1. **Use variables for flexibility.** Define template variables for namespace, service, and instance so one dashboard serves multiple contexts.
2. **Set appropriate refresh rates.** Use 30s for operational dashboards, 5m for capacity planning, and no auto-refresh for historical analysis.
3. **Configure meaningful thresholds.** Apply color steps (green/yellow/red) to stat and gauge panels so problems are visible at a glance.
4. **Add panel descriptions.** Use the panel description field to explain what the metric means and what action to take when it is abnormal.
5. **Use consistent units and decimals.** Set units (bytes, percent, seconds, requests/sec) and decimal precision explicitly on every panel.
6. **Group related panels in named rows.** Use row titles like "HTTP Layer", "Database", "Infrastructure" so viewers can collapse sections they do not need.
7. **Set a sensible default time range.** Last 6 hours for operational dashboards, last 7 days for capacity, last 30 days for trends.
8. **Use dashboard links for navigation.** Link related dashboards (overview -> service detail -> infrastructure) so users can drill down without searching.
9. **Use consistent colors across dashboards.** Pin series colors or use overrides so the same service always appears in the same color.
10. **Test with different time ranges.** Verify that queries, legends, and thresholds remain useful at both short (15m) and long (7d) ranges.

## Variables

Common template variable patterns:

```
namespace:  label_values(kube_pod_info, namespace)
service:    label_values(kube_service_info{namespace="$namespace"}, service)
instance:   label_values(up{job="$service"}, instance)
```

Use in queries: `rate(http_requests_total{namespace="$namespace", service=~"$service"}[5m])`

Set `multi: true` and `includeAll: true` on service/instance variables to allow selecting multiple targets.

## Dashboard as Code

### Grafana Provisioning (YAML)

Place JSON dashboard files in a provisioned directory:

```yaml
apiVersion: 1
providers:
  - name: "default"
    orgId: 1
    folder: "General"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /etc/grafana/dashboards
```

### Terraform

```hcl
resource "grafana_dashboard" "api_monitoring" {
  config_json = file("${path.module}/dashboards/api-monitoring.json")
  folder      = grafana_folder.monitoring.id
}
```

### Ansible

```yaml
- name: Deploy Grafana dashboards
  copy:
    src: "{{ item }}"
    dest: /etc/grafana/dashboards/
  with_fileglob:
    - "dashboards/*.json"
  notify: restart grafana
```
