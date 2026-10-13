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
        ['name' => 'api#checkIn', 'url' => '/api/v1/check-in', 'verb' => 'POST'],
        // The machine itself (device token from check-in), nobody signed in
        ['name' => 'api#contact', 'url' => '/api/v1/contact', 'verb' => 'POST'],
        ['name' => 'api#deviceSecrets', 'url' => '/api/v1/device-secrets', 'verb' => 'POST'],
        // A computer registering itself during install (enrollment token)
        ['name' => 'api#enroll', 'url' => '/api/v1/enroll', 'verb' => 'POST'],
        // NextDesk computers page: administrators and delegated groups (e.g. a helpdesk)
        ['name' => 'computers#index', 'url' => '/api/v1/computers', 'verb' => 'GET'],
        ['name' => 'computers#adminPassword', 'url' => '/api/v1/computers/{machineId}/admin-password', 'verb' => 'GET'],
        ['name' => 'computers#recoveryKey', 'url' => '/api/v1/computers/{machineId}/recovery-key', 'verb' => 'GET'],
        ['name' => 'computers#destroy', 'url' => '/api/v1/computers/{machineId}', 'verb' => 'DELETE'],
        // Public: where this server's machines get their device policy
        ['name' => 'api#devicePolicy', 'url' => '/api/v1/device-policy', 'verb' => 'GET'],
        // Administrators (settings page, Lintune)
        ['name' => 'admin_api#get', 'url' => '/api/v1/admin/policy', 'verb' => 'GET'],
        ['name' => 'admin_api#set', 'url' => '/api/v1/admin/policy', 'verb' => 'PUT'],
        ['name' => 'admin_api#getDevicePolicy', 'url' => '/api/v1/admin/device-policy', 'verb' => 'GET'],
        ['name' => 'admin_api#setDevicePolicy', 'url' => '/api/v1/admin/device-policy', 'verb' => 'PUT'],
        ['name' => 'admin_api#enrollmentTokens', 'url' => '/api/v1/admin/enrollment-tokens', 'verb' => 'GET'],
        ['name' => 'admin_api#createEnrollmentToken', 'url' => '/api/v1/admin/enrollment-tokens', 'verb' => 'POST'],
        ['name' => 'admin_api#revokeEnrollmentToken', 'url' => '/api/v1/admin/enrollment-tokens/{id}', 'verb' => 'DELETE'],
        ['name' => 'admin_api#recoveryKeys', 'url' => '/api/v1/admin/recovery-keys', 'verb' => 'GET'],
        ['name' => 'admin_api#recoveryKey', 'url' => '/api/v1/admin/recovery-keys/{device}', 'verb' => 'GET'],
        ['name' => 'admin_api#deleteRecoveryKey', 'url' => '/api/v1/admin/recovery-keys/{device}', 'verb' => 'DELETE'],
    ],
];
