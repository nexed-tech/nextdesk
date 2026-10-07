<?php

declare(strict_types=1);

namespace OCA\NextDesk\Service;

use InvalidArgumentException;
use OCA\NextDesk\AppInfo\Application;
use OCP\IAppConfig;
use OCP\IGroupManager;
use OCP\IUser;

/**
 * NextDesk policy: settings that NextDesk devices apply to a user.
 *
 * Layers, most specific wins: user override > group overrides > global > built-in default.
 * When a user is in several groups that set the same key, the strictest value wins, so
 * adding someone to a group never quietly loosens their policy (a user override still can).
 *
 * Stored in app config as JSON: "global" (object), "groups" and "users" (objects keyed by
 * group id / user id). Only the keys in self::KEYS are accepted.
 */
class PolicyService {
    /**
     * Known policy keys: default value, valid range, and which direction is stricter.
     * offline_grace_days: days a device may be used (logged in to with the offline PIN)
     * since its last successful check with this server; 0 = no offline login.
     */
    public const KEYS = [
        'offline_grace_days' => ['default' => 7, 'min' => 0, 'max' => 3650, 'stricter' => 'lower'],
    ];

    public const SCOPES = ['global', 'group', 'user'];

    public function __construct(
        private IAppConfig $appConfig,
        private IGroupManager $groupManager,
    ) {
    }

    public function defaults(): array {
        return array_map(static fn (array $key) => $key['default'], self::KEYS);
    }

    public function getGlobal(): array {
        return $this->load('global');
    }

    /** @return array<string, array> group id => policy */
    public function getGroups(): array {
        return $this->load('groups');
    }

    /** @return array<string, array> user id => policy */
    public function getUsers(): array {
        return $this->load('users');
    }

    /**
     * Sets the policy of one scope. A null or empty policy removes the group/user override
     * (or resets the global policy to the defaults).
     */
    public function set(string $scope, string $id, ?array $policy): void {
        $policy = $policy === null ? [] : $this->sanitize($policy);
        switch ($scope) {
            case 'global':
                $this->save('global', $policy);
                return;
            case 'group':
            case 'user':
                if ($id === '') {
                    throw new InvalidArgumentException("A $scope id is required");
                }
                $key = $scope === 'group' ? 'groups' : 'users';
                $all = $this->load($key);
                if ($policy === []) {
                    unset($all[$id]);
                } else {
                    $all[$id] = $policy;
                }
                $this->save($key, $all);
                return;
            default:
                throw new InvalidArgumentException("Unknown scope '$scope'; use global, group or user");
        }
    }

    /** The policy that applies to this user, with every key set. */
    public function effective(IUser $user): array {
        $policy = array_replace($this->defaults(), $this->getGlobal());

        $groups = $this->getGroups();
        $fromGroups = [];
        foreach ($this->groupManager->getUserGroupIds($user) as $gid) {
            foreach ($groups[$gid] ?? [] as $key => $value) {
                $fromGroups[$key] = isset($fromGroups[$key]) ? $this->stricter($key, $fromGroups[$key], $value) : $value;
            }
        }
        $policy = array_replace($policy, $fromGroups);

        return array_replace($policy, $this->getUsers()[$user->getUID()] ?? []);
    }

    /** Only known keys, as integers within range. */
    public function sanitize(array $policy): array {
        $clean = [];
        foreach ($policy as $key => $value) {
            if (!isset(self::KEYS[$key])) {
                throw new InvalidArgumentException("Unknown policy key '$key'");
            }
            if ($value === null || $value === '') {
                continue;
            }
            if (!is_numeric($value) || (int)$value != $value) {
                throw new InvalidArgumentException("$key must be a whole number");
            }
            $value = (int)$value;
            if ($value < self::KEYS[$key]['min'] || $value > self::KEYS[$key]['max']) {
                throw new InvalidArgumentException(sprintf('%s must be between %d and %d', $key, self::KEYS[$key]['min'], self::KEYS[$key]['max']));
            }
            $clean[$key] = $value;
        }
        return $clean;
    }

    private function stricter(string $key, int $a, int $b): int {
        return self::KEYS[$key]['stricter'] === 'lower' ? min($a, $b) : max($a, $b);
    }

    private function load(string $key): array {
        $value = json_decode($this->appConfig->getValueString(Application::APP_ID, 'policy_' . $key, '{}'), true);
        return is_array($value) ? $value : [];
    }

    private function save(string $key, array $value): void {
        $this->appConfig->setValueString(Application::APP_ID, 'policy_' . $key, json_encode((object)$value));
    }
}
