#!/usr/bin/env bash
#
# targets.sh - Prometheus' targets, up and down
#
# Copyright (c) Bankole Ogundero and the Vigil contributors
# SPDX-License-Identifier: Apache-2.0
#
# Provided "AS IS", WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
# implied. Run it at your own risk: review it first, and test it before you
# rely on it. In no event shall the authors or copyright holders be liable
# for any claim, damages or other liability arising from its use. See the
# LICENSE file for the full terms.
#
# Reports the targets Prometheus scrapes: how many are up and how many down,
# the down ones for each job, the slowest scrape, and the scrapes it had to
# cut short or reject (too many samples, samples out of order, duplicate
# timestamps). It only reads: every request is a GET, and it changes nothing.
#
# Reads PROMETHEUS_URL (default http://localhost:9090): /metrics, Prometheus'
# page about itself, and /federate for the up, scrape_duration_seconds and
# scrape_samples_scraped series (one line a target).
# What the scripts share is in _prometheus.sh, beside this one.
#
# Metrics:
#   up                           1 when Prometheus answered its metrics page,
#                                else 0 (and nothing more is read)
#   scrape_pools                 scrape jobs configured
#   targets                      targets in them
#   discovered_targets           targets service discovery found, before
#                                relabelling
#   sd_failed_configs            service discovery configurations that could
#                                not be loaded
#   pool_reloads_failed_count    scrape jobs that could not be reloaded (a
#                                running total)
#   exceeded_sample_limit_count  scrapes rejected whole: more samples than
#                                sample_limit (a running total)
#   exceeded_body_size_count     scrapes rejected whole: a page larger than
#                                body_size_limit (a running total)
#   exceeded_target_limit_count  times a scrape job had more targets than
#                                target_limit: none of them is scraped (a
#                                running total)
#   out_of_order_count           samples rejected: out of order (a running
#                                total)
#   duplicate_timestamp_count    samples rejected: the same series twice in
#                                one scrape (a running total)
#   out_of_bounds_count          samples rejected: too old or too far ahead (a
#                                running total)
#   targets_up                   targets whose last scrape worked
#   targets_down                 targets whose last scrape failed: nothing
#                                answered, or not with metrics
#   down                         the targets down in each job, tagged job=<it>
#                                (0 for a job with none down)
#   down_not_shown               how many more there were than the 20 shown
#   scrape_slowest_seconds       the slowest target's last scrape
#   samples_scraped              samples the last scrape of every target
#                                brought
#
# Example output (the rest are in the same form):
#   (draft: no example yet)
#
# Reading the results (starting points: tune them to your own):
#   Healthy  targets_down 0; the rejected counts not moving;
#            scrape_slowest_seconds well under the scrape interval.
#   Watch    scrape_slowest_seconds near the scrape timeout (a target about to
#            fail); out_of_order_count or duplicate_timestamp_count climbing
#            (an exporter printing a series twice, or two Prometheus scraping
#            into one).
#   Act      targets_down above 0 for more than a few scrapes: down says which
#            job; exceeded_sample_limit_count or exceeded_target_limit_count
#            moving: whole scrapes are being thrown away; sd_failed_configs
#            above 0.
#
# Requires: bash, curl, awk
# Exit code: 0, whatever it reads, and when Prometheus does not answer (up 0
#   is the reading); 1 when it answers wrong (a login refused, not HTTP), said
#   on stderr, or curl or awk is missing

set -u

job=targets
# shellcheck source=/dev/null
. "$(dirname "$0")/_prometheus.sh"
needs curl awk

page '/metrics'
readings <<'T'
scrape_pools|count|prometheus_target_scrape_pool_targets
targets|sum|prometheus_target_scrape_pool_targets
discovered_targets|sum|prometheus_sd_discovered_targets|name=scrape
sd_failed_configs|sum|prometheus_sd_failed_configs
pool_reloads_failed_count|sum|prometheus_target_scrape_pool_reloads_failed_total
exceeded_sample_limit_count|sum|prometheus_target_scrapes_exceeded_sample_limit_total
exceeded_body_size_count|sum|prometheus_target_scrapes_exceeded_body_size_limit_total
exceeded_target_limit_count|sum|prometheus_target_scrape_pool_exceeded_target_limit_total
out_of_order_count|sum|prometheus_target_scrapes_sample_out_of_order_total
duplicate_timestamp_count|sum|prometheus_target_scrapes_sample_duplicate_timestamp_total
out_of_bounds_count|sum|prometheus_target_scrapes_sample_out_of_bounds_total
T
if get '/federate?match[]=up&match[]=scrape_duration_seconds&match[]=scrape_samples_scraped' extra1; then
readings "$work/extra1" <<'T'
targets_up|count|up||=1
targets_down|count|up||=0
down|countby|up||job:job =0
scrape_slowest_seconds|max|scrape_duration_seconds
samples_scraped|sum|scrape_samples_scraped
T
fi
exit 0
