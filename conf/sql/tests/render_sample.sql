SELECT count() FROM {{ DB }}.usage_log
WHERE {{ time_filter('timestamp') }}
    AND environment = {{ gf_str('environment') }}
    AND region = {{ gf_str_multi('region') }}
    AND topn = {{ gf_num('topn') }}
    AND owner = {{ gf_str('owner') }};
