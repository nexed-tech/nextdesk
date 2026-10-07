<?php

declare(strict_types=1);

namespace OCA\NextDesk\Service;

use OCA\NextDesk\AppInfo\Application;
use OCP\AppFramework\Utility\ITimeFactory;
use OCP\IConfig;
use OCP\IUser;
use OCP\Security\ISecureRandom;

/**
 * One-time tokens that log a device's browser in to Nextcloud.
 *
 * A device (authenticated with its app password) gets a token and opens
 * /apps/nextdesk/login?user=<uid>&token=<token> in the browser, which then gets a normal
 * Nextcloud session. Tokens are valid once, for TTL seconds; only a hash is stored, in the
 * user's preferences, so it works without a distributed cache. A new token replaces the last.
 */
class LoginTokenService {
    public const TTL = 60;
    private const PREF = 'login_token';

    public function __construct(
        private IConfig $config,
        private ISecureRandom $random,
        private ITimeFactory $time,
    ) {
    }

    public function create(IUser $user): string {
        $token = $this->random->generate(48, ISecureRandom::CHAR_ALPHANUMERIC);
        $expires = $this->time->getTime() + self::TTL;
        $this->config->setUserValue($user->getUID(), Application::APP_ID, self::PREF, hash('sha256', $token) . ':' . $expires);
        return $token;
    }

    /** True if the token is this user's current one and not expired; it's used up either way. */
    public function consume(IUser $user, string $token): bool {
        $stored = $this->config->getUserValue($user->getUID(), Application::APP_ID, self::PREF, '');
        if ($stored === '') {
            return false;
        }
        $this->config->deleteUserValue($user->getUID(), Application::APP_ID, self::PREF);
        [$hash, $expires] = array_pad(explode(':', $stored, 2), 2, '0');
        return hash_equals($hash, hash('sha256', $token)) && (int)$expires >= $this->time->getTime();
    }
}
