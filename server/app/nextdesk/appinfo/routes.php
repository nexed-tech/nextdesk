<?php

declare(strict_types=1);

return [
    'routes' => [
        // Browser login with a one-time token (from api#sessionToken)
        ['name' => 'login#login', 'url' => '/login', 'verb' => 'GET'],
    ],
    'ocs' => [
        // Devices, authenticated with their app password
        ['name' => 'api#policy', 'url' => '/api/v1/policy', 'verb' => 'GET'],
        ['name' => 'api#sessionToken', 'url' => '/api/v1/session-token', 'verb' => 'POST'],
        // Administrators (settings page, Lintune)
        ['name' => 'admin_api#get', 'url' => '/api/v1/admin/policy', 'verb' => 'GET'],
        ['name' => 'admin_api#set', 'url' => '/api/v1/admin/policy', 'verb' => 'PUT'],
    ],
];
