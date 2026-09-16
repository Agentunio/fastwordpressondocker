<?php

// Run through wp eval-file after WordPress has loaded.
(static function ($args) {
    global $wpdb;

    $validate_url = static function ($url) {
        $parts = is_string($url) ? parse_url($url) : false;

        if (
            ! is_string($url)
            || filter_var($url, FILTER_VALIDATE_URL) === false
            || ! is_array($parts)
            || ! in_array(strtolower($parts['scheme'] ?? ''), array('http', 'https'), true)
            || empty($parts['host'])
            || isset($parts['user'])
            || isset($parts['pass'])
            || isset($parts['query'])
            || isset($parts['fragment'])
        ) {
            throw new RuntimeException('WordPress URLs must be absolute HTTP(S) URLs without credentials, a query or a fragment.');
        }

        return rtrim($url, '/');
    };

    $quote_identifier = static function ($identifier) {
        return '`' . str_replace('`', '``', $identifier) . '`';
    };

    $check_database = static function () use ($wpdb) {
        if ($wpdb->last_error !== '') {
            throw new RuntimeException('Could not synchronize WordPress URLs because a database operation failed.');
        }
    };

    $previous_suppress_errors = $wpdb->suppress_errors(true);
    $updated_values = 0;
    $skipped_tables = 0;
    $failure = null;
    $migration_started = false;

    try {
        if (count($args) !== 1) {
            throw new RuntimeException('Pass exactly one target WordPress URL.');
        }

        $target = $validate_url($args[0]);
        $options_table = $quote_identifier($wpdb->options);
        $options = $wpdb->get_results(
            "SELECT option_name, option_value FROM {$options_table} WHERE option_name IN ('home', 'siteurl')",
            OBJECT_K
        );
        $check_database();

        if (! isset($options['home'], $options['siteurl'])) {
            throw new RuntimeException('The WordPress home and siteurl options must exist before URL synchronization.');
        }

        $sources = array_unique(array(
            $validate_url($options['home']->option_value),
            $validate_url($options['siteurl']->option_value),
        ));
        $sources = array_values(array_filter($sources, static function ($source) use ($target) {
            return $source !== $target;
        }));

        if ($sources === array()) {
            \WP_CLI::success('WordPress URL unchanged; skipping synchronization.');
            return;
        }

        $migration_started = true;
        // Some supported drop-ins, including wp-memcached, return null after a successful flush.
        if (wp_cache_flush() === false) {
            throw new RuntimeException('Could not flush the object cache before WordPress URL synchronization.');
        }

        usort($sources, static function ($left, $right) {
            return strlen($right) <=> strlen($left);
        });

        $replacers = array();
        $patterns = array();
        $needles = array();
        // A host or port must end here; ':' and host suffixes must never match.
        $boundary = '(?=$|[/?#\s"\'<>()[\]{},;]|\\\\[/"\'])';

        foreach (array(false, true) as $escaped_slashes) {
            if ($sources === array()) {
                break;
            }

            $encode_url = static function ($url) use ($escaped_slashes) {
                return $escaped_slashes ? str_replace('/', '\\/', $url) : $url;
            };
            $encoded_target = $encode_url($target);
            $encoded_sources = array_map($encode_url, $sources);
            $needles = array_merge($needles, $encoded_sources);
            $alternatives = array_map(static function ($source) {
                return preg_quote($source, '~');
            }, $encoded_sources);

            // Protect URLs already at the target and replace all sources in one pass.
            $pattern = '(?!' . preg_quote($encoded_target, '~') . $boundary . ')'
                . '(?:' . implode('|', $alternatives) . ')' . $boundary;
            $replacement = strtr($encoded_target, array('\\' => '\\\\', '$' => '\\$'));
            $patterns[] = '~' . $pattern . '~';
            $replacers[] = new \WP_CLI\SearchReplacer($pattern, $replacement, true, true, '', '~', true);
        }

        if ($replacers !== array()) {
            $tables = $wpdb->get_col($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($wpdb->prefix) . '%'));
            $check_database();

            foreach ($tables as $table) {
                $quoted_table = $quote_identifier($table);
                $schema = $wpdb->get_results("SHOW FULL COLUMNS FROM {$quoted_table}", ARRAY_A);
                $check_database();
                $primary_keys = array();
                $text_columns = array();

                foreach ($schema as $column) {
                    if ($column['Key'] === 'PRI') {
                        $primary_keys[] = $column['Field'];
                    } elseif (
                        strtolower($column['Field']) !== 'guid'
                        && preg_match('/^(?:char|varchar|tinytext|text|mediumtext|longtext|json)\b/i', $column['Type'])
                        && stripos($column['Extra'], 'GENERATED') === false
                    ) {
                        $text_columns[] = $column['Field'];
                    }
                }

                if ($text_columns === array()) {
                    continue;
                }

                if ($primary_keys === array()) {
                    $skipped_tables++;
                    continue;
                }

                $quoted_keys = array_map($quote_identifier, $primary_keys);
                $selected_columns = array_map($quote_identifier, array_merge($primary_keys, $text_columns));
                $like_clauses = array();

                foreach ($text_columns as $column) {
                    foreach ($needles as $needle) {
                        $like_clauses[] = $wpdb->prepare(
                            $quote_identifier($column) . ' LIKE %s',
                            '%' . $wpdb->esc_like($needle) . '%'
                        );
                    }
                }

                $filter = '(' . implode(' OR ', $like_clauses) . ')';

                // Keep the old addresses until all content has been migrated successfully.
                if ($table === $wpdb->options) {
                    $filter .= " AND `option_name` NOT IN ('home', 'siteurl')";
                }

                $cursor = null;

                do {
                    $cursor_filter = '';

                    if ($cursor !== null) {
                        $cursor_filter = $wpdb->prepare(
                            ' AND (' . implode(', ', $quoted_keys) . ') > ('
                            . implode(', ', array_fill(0, count($primary_keys), '%s')) . ')',
                            $cursor
                        );
                    }

                    $rows = $wpdb->get_results(
                        'SELECT ' . implode(', ', $selected_columns) . " FROM {$quoted_table} WHERE {$filter}"
                        . $cursor_filter . ' ORDER BY ' . implode(', ', $quoted_keys) . ' LIMIT 250',
                        ARRAY_A
                    );
                    $check_database();

                    foreach ($rows as $row) {
                        $updates = array();
                        $where = array();

                        foreach ($primary_keys as $key) {
                            $where[$key] = $row[$key];
                        }

                        foreach ($text_columns as $column) {
                            $original = $row[$column];

                            if (! is_string($original)) {
                                continue;
                            }

                            $value = $original;

                            foreach ($replacers as $index => $replacer) {
                                $matches = preg_match($patterns[$index], $value);

                                if ($matches === false) {
                                    throw new RuntimeException('Could not match a stored WordPress URL safely.');
                                }

                                if ($matches === 0) {
                                    continue;
                                }

                                $replacer->clear_log_data();
                                $candidate = $replacer->run($value);

                                // Unserialization alone may normalize bytes; only save actual URL replacements.
                                if ($replacer->get_log_data() !== array()) {
                                    if (! is_string($candidate)) {
                                        throw new RuntimeException('Could not safely replace a stored WordPress URL.');
                                    }

                                    $value = $candidate;
                                }
                            }

                            if ($value !== $original) {
                                $updates[$column] = $value;
                            }
                        }

                        if ($updates !== array()) {
                            $written = $wpdb->update($table, $updates, $where);
                            $check_database();

                            if ($written === false) {
                                throw new RuntimeException('Could not save migrated WordPress URLs.');
                            }

                            $updated_values += count($updates);
                        }

                        $cursor = array_values($where);
                    }
                } while (count($rows) === 250);
            }
        }

        if (wp_cache_flush() === false) {
            throw new RuntimeException('Could not flush migrated WordPress URLs from the object cache.');
        }

        foreach (array('home', 'siteurl') as $option) {
            update_option($option, $target);
            $check_database();
            $saved = $wpdb->get_var($wpdb->prepare(
                "SELECT option_value FROM {$options_table} WHERE option_name = %s",
                $option
            ));
            $check_database();

            if ($saved !== $target) {
                throw new RuntimeException('Could not save the target WordPress home or siteurl option.');
            }
        }
    } catch (RuntimeException $error) {
        $failure = $error->getMessage();
    } catch (Throwable $error) {
        $failure = 'WordPress URL synchronization failed unexpectedly.';
    } finally {
        if ($migration_started && wp_cache_flush() === false && $failure === null) {
            $failure = 'Could not flush the object cache after WordPress URL synchronization.';
        }
        $wpdb->suppress_errors($previous_suppress_errors);
    }

    if ($failure !== null) {
        \WP_CLI::error($failure);
    }

    if ($skipped_tables > 0) {
        \WP_CLI::warning(sprintf('Skipped %d tables without a primary key during URL synchronization.', $skipped_tables));
    }

    \WP_CLI::success(sprintf('WordPress URL synchronized; updated %d stored values.', $updated_values));
})($args);
