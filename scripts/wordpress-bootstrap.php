<?php

require_once __DIR__ . '/default-admin-guardian.php';

register_shutdown_function('fast_wordpress_ensure_default_admin');
