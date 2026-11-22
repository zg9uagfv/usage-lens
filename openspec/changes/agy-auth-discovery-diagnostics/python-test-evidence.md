# Isolated Python Reference Probe Validation Evidence (`agy-auth-discovery-diagnostics`)

- **Timestamp**: 2026-11-22 18:14:39 +0800
- **HEAD Commit**: `11bc5649672a271e989f37818f55d7ebc7c113e4`
- **Python Toolchain**: `Python 3.14.8`
- **Command**: `python3 -m unittest discover -s tests -p "test_*.py" -v`
- **Exit Code**: `0`
- **Duration**: `11.817s`
- **Totals**: `101` executed, `0` failed, `0` skipped (`OK`)
- **Runtime Scope Note**: Native Swift `ProbeRunner` no longer spawns `python3` at runtime; these four dirty Python files (`probes/agy.py`, `probes/gemini.py`, `tests/test_agy.py`, `tests/test_gemini.py`) remain part of the dirty delivery scope and are copied into `UsageLens.app/Contents/Resources/probes/` by `app/Scripts/build-app.sh`. This isolated, synthetic suite validates all four changed Python files plus the unchanged Codex/DeepSeek Python suites without touching real credentials or live network endpoints (localhost loopback sockets used solely for synthetic redirect/security tests).

## Reproducible File Digests (SHA-256)

- **4 Dirty Python Files Combined Digest**: `b1680c8aa532a9aa2b7654aeb2dc16872b5e3bddcd36cfc3b8976cb0000aeca7`
  - Recipe: `LC_ALL=C cat probes/agy.py probes/gemini.py tests/test_agy.py tests/test_gemini.py | shasum -a 256`
- **All 8 Python Probe & Test Files Combined Digest**: `42ce44191ec17849f55299d9fa4145204387fb86348dd0665741eeb550eb436d`
  - Recipe: `LC_ALL=C cat probes/agy.py probes/codex.py probes/deepseek.py probes/gemini.py tests/test_agy.py tests/test_codex.py tests/test_deepseek.py tests/test_gemini.py | shasum -a 256`

| File | SHA-256 |
| --- | --- |
| `probes/agy.py` | `6b56f4b26c41489b4693b4b9617e0d326add730016e8e086cce0e42d88c7aa80` |
| `probes/codex.py` | `4aba49ab2e750f2a0a3373f51ddd4a1765e05e945fccda22c1c0f361f985351f` |
| `probes/deepseek.py` | `89ac023ce9eb783cfab45f43c2f44084fe3b91607b6c3a97aef92b2e548f53a4` |
| `probes/gemini.py` | `7e22f3eb5322ece771cdaf0267693760d21fdf973a01ec19439fb6c6938f02a9` |
| `tests/test_agy.py` | `2ba315a095048d0de291f925164b96d0b5ff9879aaaa5f470e277a4a4280fa4a` |
| `tests/test_codex.py` | `6930fce562f2231b6069a67298482049c72d1d98254c226ff48867d3b088b797` |
| `tests/test_deepseek.py` | `fb54feaff68366a068bee39ff3af919168373fa2499ef5aba319829149bd569a` |
| `tests/test_gemini.py` | `b72eac9176733f5454ae9ebcfdabaf81607a80ecb4b4f91a4a8eaba90c3c8d74` |

## Suite Breakdown

| Suite | Executed | Failures | Skips | Result |
| --- | ---: | ---: | ---: | --- |
| `test_agy.AgyProbeTest` | 21 | 0 | 0 | PASS |
| `test_codex.CodexLiveServerTest` | 7 | 0 | 0 | PASS |
| `test_codex.CodexProbeTest` | 20 | 0 | 0 | PASS |
| `test_deepseek.DeepSeekProbeTest` | 26 | 0 | 0 | PASS |
| `test_gemini.GeminiProbeTest` | 27 | 0 | 0 | PASS |
| **Total** | **101** | **0** | **0** | **PASS** |

## Complete Sanitized Unittest Output

```text
test_api_keys_gemini_clients_and_google_project_aliases_do_not_affect_agy (test_agy.AgyProbeTest.test_api_keys_gemini_clients_and_google_project_aliases_do_not_affect_agy) ... ok
test_disable_local_auth_skips_auth_file_and_network (test_agy.AgyProbeTest.test_disable_local_auth_skips_auth_file_and_network) ... ok
test_discovery_failure_preserves_local_today_tokens_without_fake_quota (test_agy.AgyProbeTest.test_discovery_failure_preserves_local_today_tokens_without_fake_quota) ... ok
test_expired_auth_without_client_id_fallback (test_agy.AgyProbeTest.test_expired_auth_without_client_id_fallback) ... ok
test_host_pinning (test_agy.AgyProbeTest.test_host_pinning) ... ok
test_isolated_home_zero_network_and_zero_writes (test_agy.AgyProbeTest.test_isolated_home_zero_network_and_zero_writes) ... ok
test_keychain_available_via_fake_security_and_no_enumeration (test_agy.AgyProbeTest.test_keychain_available_via_fake_security_and_no_enumeration) ... ok
test_keychain_discovery_outcomes_differentiated_and_secret_free (test_agy.AgyProbeTest.test_keychain_discovery_outcomes_differentiated_and_secret_free) ... ok
test_keyring_base64_and_live_conservative_max_aggregation (test_agy.AgyProbeTest.test_keyring_base64_and_live_conservative_max_aggregation) ... ok
test_local_file_malformed_unreadable_and_isolated_home_skips_security (test_agy.AgyProbeTest.test_local_file_malformed_unreadable_and_isolated_home_skips_security) ... ok
test_local_today_tokens_aggregation_and_truncation (test_agy.AgyProbeTest.test_local_today_tokens_aggregation_and_truncation) ... ok
test_oversized_response_rejected (test_agy.AgyProbeTest.test_oversized_response_rejected) ... ok
test_partial_endpoint_failure_and_malformed_values (test_agy.AgyProbeTest.test_partial_endpoint_failure_and_malformed_values) ... ok
test_proactive_in_memory_oauth_refresh_zero_writes (test_agy.AgyProbeTest.test_proactive_in_memory_oauth_refresh_zero_writes) ... ok
test_reactive_401_refresh_retries_at_most_once (test_agy.AgyProbeTest.test_reactive_401_refresh_retries_at_most_once) ... ok
test_redirect_302_blocked_without_leaking_auth_header (test_agy.AgyProbeTest.test_redirect_302_blocked_without_leaking_auth_header) ... ok
test_secret_redaction (test_agy.AgyProbeTest.test_secret_redaction) ... ok
test_server_401_and_rejected_oauth_refresh_stay_bounded_and_honest (test_agy.AgyProbeTest.test_server_401_and_rejected_oauth_refresh_stay_bounded_and_honest) ... ok
test_server_403_reports_permission_denial_without_claiming_expiration_or_missing (test_agy.AgyProbeTest.test_server_403_reports_permission_denial_without_claiming_expiration_or_missing) ... ok
test_source_precedence_order (test_agy.AgyProbeTest.test_source_precedence_order) ... ok
test_utc_local_date_boundary_aggregates_local_today_tokens (test_agy.AgyProbeTest.test_utc_local_date_boundary_aggregates_local_today_tokens) ... ok
test_is_official_url_unit (test_codex.CodexLiveServerTest.test_is_official_url_unit) ... ok
test_live_200_success_returns_realtime_windows_account_and_today_tokens (test_codex.CodexLiveServerTest.test_live_200_success_returns_realtime_windows_account_and_today_tokens) ... ok
test_live_failure_with_empty_local_logs_exits_zero_with_both_warnings (test_codex.CodexLiveServerTest.test_live_failure_with_empty_local_logs_exits_zero_with_both_warnings) ... ok
test_live_failures_gracefully_fallback_to_local_logs (test_codex.CodexLiveServerTest.test_live_failures_gracefully_fallback_to_local_logs) ... ok
test_live_invalid_nan_and_expired_values_stay_strict_json (test_codex.CodexLiveServerTest.test_live_invalid_nan_and_expired_values_stay_strict_json) ... ok
test_redirect_refused_and_never_leaks_headers (test_codex.CodexLiveServerTest.test_redirect_refused_and_never_leaks_headers) ... ok
test_secret_redaction_strips_jwt_bearer_sk_and_google_tokens_across_channels (test_codex.CodexLiveServerTest.test_secret_redaction_strips_jwt_bearer_sk_and_google_tokens_across_channels) ... ok
test_boolean_resets_at_is_ignored (test_codex.CodexProbeTest.test_boolean_resets_at_is_ignored) ... ok
test_corrupt_lines_after_valid_frame_are_skipped (test_codex.CodexProbeTest.test_corrupt_lines_after_valid_frame_are_skipped) ... ok
test_corrupt_lines_do_not_crash (test_codex.CodexProbeTest.test_corrupt_lines_do_not_crash) ... ok
test_empty_sessions_dir_exits_zero_with_warning (test_codex.CodexProbeTest.test_empty_sessions_dir_exits_zero_with_warning) ... ok
test_expired_windows_get_flag_and_warning (test_codex.CodexProbeTest.test_expired_windows_get_flag_and_warning) ... ok
test_json_flag_accepted (test_codex.CodexProbeTest.test_json_flag_accepted) ... ok
test_large_log_scans_tail_fast (test_codex.CodexProbeTest.test_large_log_scans_tail_fast) ... ok
test_log_without_rate_limits_exits_zero_with_warning (test_codex.CodexProbeTest.test_log_without_rate_limits_exits_zero_with_warning) ... ok
test_missing_sessions_dir_exits_zero_with_warning (test_codex.CodexProbeTest.test_missing_sessions_dir_exits_zero_with_warning) ... ok
test_nan_used_percent_is_null_and_output_is_strict_json (test_codex.CodexProbeTest.test_nan_used_percent_is_null_and_output_is_strict_json) ... ok
test_normal_fixture_last_frame_and_contract (test_codex.CodexProbeTest.test_normal_fixture_last_frame_and_contract) ... ok
test_out_of_range_used_percent_becomes_null_with_warning (test_codex.CodexProbeTest.test_out_of_range_used_percent_becomes_null_with_warning) ... ok
test_oversized_log_gives_truncated_scan_warning (test_codex.CodexProbeTest.test_oversized_log_gives_truncated_scan_warning) ... ok
test_same_mtime_uses_content_timestamp_in_both_orders (test_codex.CodexProbeTest.test_same_mtime_uses_content_timestamp_in_both_orders) ... ok
test_skips_newest_file_without_rate_limits (test_codex.CodexProbeTest.test_skips_newest_file_without_rate_limits) ... ok
test_stale_when_observed_older_than_window (test_codex.CodexProbeTest.test_stale_when_observed_older_than_window) ... ok
test_today_tokens_are_locally_aggregated (test_codex.CodexProbeTest.test_today_tokens_are_locally_aggregated) ... ok
test_unknown_argument_returns_exit_2_and_single_json_line (test_codex.CodexProbeTest.test_unknown_argument_returns_exit_2_and_single_json_line) ... ok
test_used_percent_missing_is_null_not_zero (test_codex.CodexProbeTest.test_used_percent_missing_is_null_not_zero) ... ok
test_window_minutes_mapping_and_fallback (test_codex.CodexProbeTest.test_window_minutes_mapping_and_fallback) ... ok
test_balance_bad_bodies_become_warnings (test_deepseek.DeepSeekProbeTest.test_balance_bad_bodies_become_warnings) ... ok
test_balance_error_messages_are_human (test_deepseek.DeepSeekProbeTest.test_balance_error_messages_are_human) ... ok
test_balance_official_source_with_mocked_network (test_deepseek.DeepSeekProbeTest.test_balance_official_source_with_mocked_network) ... ok
test_balance_prefers_cny_when_multiple_currencies (test_deepseek.DeepSeekProbeTest.test_balance_prefers_cny_when_multiple_currencies) ... ok
test_both_sources_prefers_projcache (test_deepseek.DeepSeekProbeTest.test_both_sources_prefers_projcache) ... ok
test_corrupt_archive_is_skipped_with_warning (test_deepseek.DeepSeekProbeTest.test_corrupt_archive_is_skipped_with_warning) ... ok
test_events_aggregate_multiple_days (test_deepseek.DeepSeekProbeTest.test_events_aggregate_multiple_days) ... ok
test_events_only_usage_shape (test_deepseek.DeepSeekProbeTest.test_events_only_usage_shape) ... ok
test_final_url_must_be_official (test_deepseek.DeepSeekProbeTest.test_final_url_must_be_official) ... ok
test_is_official_url_unit (test_deepseek.DeepSeekProbeTest.test_is_official_url_unit) ... ok
test_missing_dsh_dirs_give_warnings (test_deepseek.DeepSeekProbeTest.test_missing_dsh_dirs_give_warnings) ... ok
test_missing_zstd_gives_warning (test_deepseek.DeepSeekProbeTest.test_missing_zstd_gives_warning) ... ok
test_no_key_exits_zero_balance_null_with_warning (test_deepseek.DeepSeekProbeTest.test_no_key_exits_zero_balance_null_with_warning) ... ok
test_no_key_makes_no_network_call (test_deepseek.DeepSeekProbeTest.test_no_key_makes_no_network_call) ... ok
test_output_is_strict_json (test_deepseek.DeepSeekProbeTest.test_output_is_strict_json) ... ok
test_probe_writes_no_files (test_deepseek.DeepSeekProbeTest.test_probe_writes_no_files) ... ok
test_projcache_real_shape_drives_spend (test_deepseek.DeepSeekProbeTest.test_projcache_real_shape_drives_spend) ... ok
test_projcache_zero_totals_falls_back_to_events (test_deepseek.DeepSeekProbeTest.test_projcache_zero_totals_falls_back_to_events) ... ok
test_redirect_never_leaks_authorization (test_deepseek.DeepSeekProbeTest.test_redirect_never_leaks_authorization) ... ok
test_spend_window_excludes_events_older_than_7_days (test_deepseek.DeepSeekProbeTest.test_spend_window_excludes_events_older_than_7_days) ... ok
test_spend_window_excludes_projcache_older_than_7_days (test_deepseek.DeepSeekProbeTest.test_spend_window_excludes_projcache_older_than_7_days) ... ok
test_unknown_argument_returns_exit_2_and_single_json_line (test_deepseek.DeepSeekProbeTest.test_unknown_argument_returns_exit_2_and_single_json_line) ... ok
test_unrecognized_usage_fields_warn (test_deepseek.DeepSeekProbeTest.test_unrecognized_usage_fields_warn) ... ok
test_usage_event_without_time_uses_mtime_and_warns (test_deepseek.DeepSeekProbeTest.test_usage_event_without_time_uses_mtime_and_warns) ... ok
test_windows_always_empty_and_error_clear (test_deepseek.DeepSeekProbeTest.test_windows_always_empty_and_error_clear) ... ok
test_zstd_timeout_is_a_warning_not_a_hang (test_deepseek.DeepSeekProbeTest.test_zstd_timeout_is_a_warning_not_a_hang) ... ok
test_api_keys_and_project_aliases_never_authenticate_or_enter_oauth_requests (test_gemini.GeminiProbeTest.test_api_keys_and_project_aliases_never_authenticate_or_enter_oauth_requests) ... ok
test_disable_local_auth_env_hits_zero_network_gate (test_gemini.GeminiProbeTest.test_disable_local_auth_env_hits_zero_network_gate) ... ok
test_expired_and_invalid_values_stay_strict_json (test_gemini.GeminiProbeTest.test_expired_and_invalid_values_stay_strict_json) ... ok
test_expired_local_token_without_refresh_or_failed_refresh_exits_nonzero (test_gemini.GeminiProbeTest.test_expired_local_token_without_refresh_or_failed_refresh_exits_nonzero) ... ok
test_explicit_google_cloud_project_bounded_401_refresh_and_403_denial (test_gemini.GeminiProbeTest.test_explicit_google_cloud_project_bounded_401_refresh_and_403_denial) ... ok
test_explicit_project_id_sends_load_code_assist_fields_and_keeps_selected_project (test_gemini.GeminiProbeTest.test_explicit_project_id_sends_load_code_assist_fields_and_keeps_selected_project) ... ok
test_http_errors_produce_chinese_error_and_nonzero_exit (test_gemini.GeminiProbeTest.test_http_errors_produce_chinese_error_and_nonzero_exit) ... ok
test_is_official_oauth_url_unit (test_gemini.GeminiProbeTest.test_is_official_oauth_url_unit) ... ok
test_is_official_url_unit (test_gemini.GeminiProbeTest.test_is_official_url_unit) ... ok
test_local_email_falls_back_to_id_token_jwt_claim (test_gemini.GeminiProbeTest.test_local_email_falls_back_to_id_token_jwt_claim) ... ok
test_local_fresh_oauth_creds_reused_readonly_with_google_accounts_email (test_gemini.GeminiProbeTest.test_local_fresh_oauth_creds_reused_readonly_with_google_accounts_email) ... ok
test_manual_env_overrides_local_oauth_creds (test_gemini.GeminiProbeTest.test_manual_env_overrides_local_oauth_creds) ... ok
test_multi_bucket_aggregation_picks_highest_usage (test_gemini.GeminiProbeTest.test_multi_bucket_aggregation_picks_highest_usage) ... ok
test_no_account_exits_zero_with_guidance_and_zero_files (test_gemini.GeminiProbeTest.test_no_account_exits_zero_with_guidance_and_zero_files) ... ok
test_no_account_or_blank_token_makes_zero_network_calls (test_gemini.GeminiProbeTest.test_no_account_or_blank_token_makes_zero_network_calls) ... ok
test_no_project_metadata_only_and_missing_discovered_project_guidance (test_gemini.GeminiProbeTest.test_no_project_metadata_only_and_missing_discovered_project_guidance) ... ok
test_numeric_project_number_rejected_without_echoing_input (test_gemini.GeminiProbeTest.test_numeric_project_number_rejected_without_echoing_input) ... ok
test_partial_window_warns_without_fabricating_zero (test_gemini.GeminiProbeTest.test_partial_window_warns_without_fabricating_zero) ... ok
test_proactive_in_memory_refresh_on_expired_local_token_writes_zero_files (test_gemini.GeminiProbeTest.test_proactive_in_memory_refresh_on_expired_local_token_writes_zero_files) ... ok
test_project_precedence_and_trimming_across_manual_and_local_oauth (test_gemini.GeminiProbeTest.test_project_precedence_and_trimming_across_manual_and_local_oauth) ... ok
test_reactive_in_memory_refresh_on_http_401_writes_zero_files (test_gemini.GeminiProbeTest.test_reactive_in_memory_refresh_on_http_401_writes_zero_files) ... ok
test_redirect_never_leaks_authorization (test_gemini.GeminiProbeTest.test_redirect_never_leaks_authorization) ... ok
test_refresh_redirect_rejected_without_leaking_refresh_token (test_gemini.GeminiProbeTest.test_refresh_redirect_rejected_without_leaking_refresh_token) ... ok
test_secret_redaction_strips_google_tokens_and_jwt (test_gemini.GeminiProbeTest.test_secret_redaction_strips_google_tokens_and_jwt) ... ok
test_timeout_malformed_json_and_oversized_response (test_gemini.GeminiProbeTest.test_timeout_malformed_json_and_oversized_response) ... ok
test_unknown_argument_exits_2_with_single_json_line (test_gemini.GeminiProbeTest.test_unknown_argument_exits_2_with_single_json_line) ... ok
test_valid_account_returns_5h_and_7d_windows (test_gemini.GeminiProbeTest.test_valid_account_returns_5h_and_7d_windows) ... ok

----------------------------------------------------------------------
Ran 101 tests in 11.817s

OK
```
