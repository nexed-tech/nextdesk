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
        ['name' => 'api#recoveryKey', 'url' => '/api/v1/recovery-key', 'verb' => 'POST'],
        // Public: where this server's machines get their device policy
        ['name' => 'api#devicePolicy', 'url' => '/api/v1/device-policy', 'verb' => 'GET'],
        // Administrators (settings page, Lintune)
        ['name' => 'admin_api#get', 'url' => '/api/v1/admin/policy', 'verb' => 'GET'],
        ['name' => 'admin_api#set', 'url' => '/api/v1/admin/policy', 'verb' => 'PUT'],
        ['name' => 'admin_api#getDevicePolicy', 'url' => '/api/v1/admin/device-policy', 'verb' => 'GET'],
        ['name' => 'admin_api#setDevicePolicy', 'url' => '/api/v1/admin/device-policy', 'verb' => 'PUT'],
        ['name' => 'admin_api#recoveryKeys', 'url' => '/api/v1/admin/recovery-keys', 'verb' => 'GET'],
        ['name' => 'admin_api#recoveryKey', 'url' => '/api/v1/admin/recovery-keys/{device}', 'verb' => 'GET'],
        ['name' => 'admin_api#deleteRecoveryKey', 'url' => '/api/v1/admin/recovery-keys/{device}', 'verb' => 'DELETE'],
    ],
];
