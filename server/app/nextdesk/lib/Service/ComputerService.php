<?php

declare(strict_types=1);

namespace OCA\NextDesk\Service;

use InvalidArgumentException;
use OCP\DB\QueryBuilder\IQueryBuilder;
use OCP\IDBConnection;
use OCP\Security\ICrypto;
use OCP\Security\ISecureRandom;
use Psr\Log\LoggerInterface;

/**
 * NextDesk computers, one per machine id: what they report (hostname, last user, the policy in
 * force and when it was applied, package version, last contact), and their disk recovery key
 * (escrow, like BitLocker keys in Intune).
 *
 * The machine also reports when NextDesk OS was installed on it. A computer is registered by a report with a signed-in user's app password (check-in), which also
 * hands it a device token. With that token the machine itself (root, nobody signed in) reports its
 * contacts and policy. Recovery keys are stored encrypted with the instance secret (ICrypto);
 * every read is logged with who read it.
 */
class ComputerService {
    private const TABLE = 'nextdesk_computers';
    // systemd-cryptenroll recovery keys: 8 groups of 8 modhex characters
    private const KEY_RE = '/^([cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}$/';
    private const FIELDS = ['machine_id', 'hostname', 'user_id', 'user_seen_at', 'last_contact', 'policy_name',
        'policy_serial', 'policy_source', 'policy_applied_at', 'version', 'installed_at', 'disk_uuid', 'key_user_id',
        'key_updated_at', 'created_at', 'admin_user', 'admin_password_at', 'admin_password_shown_at', 'enroll_token_id'];
    public const MAX_LIMIT = 200;

    public function __construct(
        private IDBConnection $db,
        private ICrypto $crypto,
        private ISecureRandom $random,
        private LoggerInterface $logger,
    ) {
    }

    /**
     * A device reports with a signed-in user's app password: registers it, records the user. Returns
     * a new device token when it has none yet or asks for one ($newToken), else null.
     *
     * @param array{name?: string, serial?: int|string, source?: string, applied_at?: int|string} $policy
     */
    public function checkIn(string $machineId, string $hostname, string $userId, array $policy, string $version,
        int $installedAt, bool $newToken): ?string {
        $machineId = $this->machineId($machineId);
        $now = time();
        $fields = ['hostname' => $this->hostname($hostname), 'user_id' => $userId, 'user_seen_at' => $now,
            'last_contact' => $now] + $this->reported($policy, $version, $installedAt);
        $token = null;
        if ($newToken || $this->tokenHash($machineId) === '') {
            $token = $this->random->generate(48, ISecureRandom::CHAR_ALPHANUMERIC);
            $fields['token_hash'] = hash('sha256', $token);
        }
        $this->upsert($machineId, $fields);
        return $token;
    }

    /**
     * A computer registers itself during install with an enrollment token (already checked):
     * registered with a new device token, which is returned.
     */
    public function enroll(string $machineId, string $hostname, string $version, int $installedAt, int $tokenId): string {
        $machineId = $this->machineId($machineId);
        $token = $this->random->generate(48, ISecureRandom::CHAR_ALPHANUMERIC);
        $this->upsert($machineId, ['hostname' => $this->hostname($hostname), 'last_contact' => time(),
            'token_hash' => hash('sha256', $token), 'enroll_token_id' => $tokenId]
            + $this->reported([], $version, $installedAt));
        $this->logger->info("NextDesk: computer $hostname ($machineId) enrolled with token $tokenId", ['app' => 'nextdesk']);
        return $token;
    }

    /**
     * The machine reports itself (device token, nobody needs to be signed in): last contact, and
     * the policy and version when given. Null for an unknown machine or a wrong token; else
     * {rotate_admin_password}: true when its admin password was shown after it was set, so the
     * machine sets a new one.
     *
     * @param array{name?: string, serial?: int|string, source?: string, applied_at?: int|string} $policy
     */
    public function contact(string $machineId, string $token, array $policy, string $version, int $installedAt): ?array {
        $machineId = $this->authenticated($machineId, $token);
        if ($machineId === null) {
            return null;
        }
        $this->upsert($machineId, ['last_contact' => time()] + $this->reported($policy, $version, $installedAt));
        $qb = $this->db->getQueryBuilder();
        $result = $qb->select('admin_password_at', 'admin_password_shown_at')->from(self::TABLE)
            ->where($qb->expr()->eq('machine_id', $qb->createNamedParameter($machineId)))->executeQuery();
        $row = $result->fetch();
        $result->closeCursor();
        return ['rotate_admin_password' => $row !== false && (int)$row['admin_password_at'] > 0
            && (int)$row['admin_password_shown_at'] >= (int)$row['admin_password_at']];
    }

    /**
     * The machine stores its own secrets with its device token: its disk recovery key and/or its
     * local admin password. False for an unknown machine or a wrong token.
     */
    public function storeSecrets(string $machineId, string $token, string $recoveryKey, string $diskUuid,
        string $adminUser, string $adminPassword): bool {
        $machineId = $this->authenticated($machineId, $token);
        if ($machineId === null) {
            return false;
        }
        $now = time();
        $fields = ['last_contact' => $now];
        if ($recoveryKey !== '') {
            $key = strtolower(trim($recoveryKey));
            if (!preg_match(self::KEY_RE, $key)) {
                throw new InvalidArgumentException('Invalid recovery key');
            }
            $fields += ['recovery_key' => $this->crypto->encrypt($key), 'key_user_id' => '', 'key_updated_at' => $now,
                'disk_uuid' => preg_match('/^[0-9a-fA-F-]{1,64}$/', $diskUuid) ? strtolower($diskUuid) : ''];
        }
        if ($adminPassword !== '') {
            if (!preg_match('/^[a-z_][a-z0-9_-]{0,31}$/', $adminUser)) {
                throw new InvalidArgumentException('Invalid admin user name');
            }
            if (strlen($adminPassword) < 16 || strlen($adminPassword) > 128 || !ctype_print($adminPassword)) {
                throw new InvalidArgumentException('Invalid admin password');
            }
            $fields += ['admin_user' => $adminUser, 'admin_password' => $this->crypto->encrypt($adminPassword),
                'admin_password_at' => $now];
        }
        $this->upsert($machineId, $fields);
        $this->logger->info("NextDesk: computer $machineId stored its "
            . implode(' and ', array_filter([$recoveryKey !== '' ? 'recovery key' : '', $adminPassword !== '' ? 'admin password' : ''])),
            ['app' => 'nextdesk']);
        return true;
    }

    /**
     * A computer's local admin account and password (computers page). Logged: who saw which.
     * Marks it shown, so the machine sets a new one at its next contact.
     *
     * @return array{hostname: string, admin_user: string, admin_password: string}|null
     */
    public function revealAdminPassword(string $machineId, string $by): ?array {
        $qb = $this->db->getQueryBuilder();
        $result = $qb->select('hostname', 'admin_user', 'admin_password')->from(self::TABLE)
            ->where($qb->expr()->eq('machine_id', $qb->createNamedParameter(strtolower($machineId))))
            ->andWhere($qb->expr()->isNotNull('admin_password'))->executeQuery();
        $row = $result->fetch();
        $result->closeCursor();
        if ($row === false) {
            return null;
        }
        $this->upsert(strtolower($machineId), ['admin_password_shown_at' => time()]);
        $this->logger->warning("NextDesk: admin password of {$row['hostname']} ($machineId) shown to $by; the computer sets a new one",
            ['app' => 'nextdesk']);
        return ['hostname' => $row['hostname'], 'admin_user' => $row['admin_user'] ?? '',
            'admin_password' => $this->crypto->decrypt($row['admin_password'])];
    }

    /** The normalized machine id when the device token matches, else null. */
    private function authenticated(string $machineId, string $token): ?string {
        try {
            $machineId = $this->machineId($machineId);
        } catch (InvalidArgumentException) {
            return null;
        }
        $hash = $this->tokenHash($machineId);
        if ($hash === '' || !hash_equals($hash, hash('sha256', $token))) {
            return null;
        }
        return $machineId;
    }

    public function storeRecoveryKey(string $machineId, string $hostname, string $diskUuid, string $userId, string $key): void {
        $machineId = $this->machineId($machineId);
        $key = strtolower(trim($key));
        if (!preg_match(self::KEY_RE, $key)) {
            throw new InvalidArgumentException('Invalid recovery key');
        }
        $hostname = $this->hostname($hostname);
        $now = time();
        $this->upsert($machineId, [
            'hostname' => $hostname,
            'user_id' => $userId,
            'user_seen_at' => $now,
            'last_contact' => $now,
            'disk_uuid' => preg_match('/^[0-9a-fA-F-]{1,64}$/', $diskUuid) ? strtolower($diskUuid) : '',
            'recovery_key' => $this->crypto->encrypt($key),
            'key_user_id' => $userId,
            'key_updated_at' => $now,
        ]);
        $this->logger->info("NextDesk: recovery key of $hostname ($machineId) stored, sent by $userId", ['app' => 'nextdesk']);
    }

    /**
     * A page of computers, most recent contact first, without keys (has_key says whether one is
     * stored). The search matches hostname, machine id and last user.
     *
     * @return array{computers: list<array>, total: int}
     */
    public function search(string $search = '', int $limit = 50, int $offset = 0): array {
        $limit = max(1, min($limit, self::MAX_LIMIT));
        $offset = max(0, $offset);
        $qb = $this->db->getQueryBuilder();
        $qb->select(...self::FIELDS)->selectAlias($qb->createFunction('CASE WHEN recovery_key IS NULL THEN 0 ELSE 1 END'), 'has_key')
            ->selectAlias($qb->createFunction('CASE WHEN admin_password IS NULL THEN 0 ELSE 1 END'), 'has_admin_password')
            ->from(self::TABLE);
        $this->filter($qb, $search);
        $qb->orderBy('last_contact', 'DESC')->addOrderBy('hostname')->setMaxResults($limit)->setFirstResult($offset);
        $result = $qb->executeQuery();
        $computers = [];
        while ($row = $result->fetch()) {
            $computers[] = $this->format($row);
        }
        $result->closeCursor();

        $count = $this->db->getQueryBuilder();
        $count->select($count->func()->count('*', 'total'))->from(self::TABLE);
        $this->filter($count, $search);
        $result = $count->executeQuery();
        $total = (int)$result->fetchOne();
        $result->closeCursor();
        return ['computers' => $computers, 'total' => $total];
    }

    /** All computers with a stored recovery key, without the keys (occ, the old admin API). */
    public function withKeys(): array {
        $qb = $this->db->getQueryBuilder();
        $result = $qb->select(...self::FIELDS)->from(self::TABLE)
            ->where($qb->expr()->isNotNull('recovery_key'))
            ->orderBy('hostname')->executeQuery();
        $rows = [];
        while ($row = $result->fetch()) {
            $row['has_key'] = 1;
            $rows[] = $this->format($row);
        }
        $result->closeCursor();
        return $rows;
    }

    /**
     * The computers matching a machine id or hostname that have a key, with it. Logged: who read
     * which.
     */
    public function revealKey(string $machineIdOrHostname, string $by): array {
        $qb = $this->db->getQueryBuilder();
        $result = $qb->select('*')->from(self::TABLE)
            ->where($qb->expr()->isNotNull('recovery_key'))
            ->andWhere($qb->expr()->orX(
                $qb->expr()->eq('machine_id', $qb->createNamedParameter(strtolower($machineIdOrHostname))),
                $qb->expr()->eq('hostname', $qb->createNamedParameter($machineIdOrHostname)),
            ))
            ->executeQuery();
        $rows = [];
        while ($row = $result->fetch()) {
            $row['has_key'] = 1;
            $computer = $this->format($row);
            $computer['recovery_key'] = $this->crypto->decrypt($row['recovery_key']);
            $rows[] = $computer;
            $this->logger->warning("NextDesk: recovery key of {$row['hostname']} ({$row['machine_id']}) shown to $by",
                ['app' => 'nextdesk']);
        }
        $result->closeCursor();
        return $rows;
    }

    /** Removes a computer (and its recovery key): for a computer that no longer exists. */
    public function delete(string $machineId, string $by): bool {
        $qb = $this->db->getQueryBuilder();
        $deleted = $qb->delete(self::TABLE)
            ->where($qb->expr()->eq('machine_id', $qb->createNamedParameter(strtolower($machineId))))
            ->executeStatement() > 0;
        if ($deleted) {
            $this->logger->warning("NextDesk: computer $machineId (and its recovery key) deleted by $by", ['app' => 'nextdesk']);
        }
        return $deleted;
    }

    /** The reported policy, version and install time as columns (only what was reported). */
    private function reported(array $policy, string $version, int $installedAt): array {
        $fields = [];
        if (trim((string)($policy['name'] ?? '')) !== '') {
            $serial = $policy['serial'] ?? 0;
            $applied = $policy['applied_at'] ?? 0;
            $fields += [
                'policy_name' => mb_substr(trim((string)$policy['name']), 0, 64),
                'policy_serial' => is_numeric($serial) && (int)$serial > 0 ? (int)$serial : 0,
                'policy_source' => mb_substr(trim((string)($policy['source'] ?? '')), 0, 1024),
                // the machine's own clock; never in the future
                'policy_applied_at' => is_numeric($applied) && (int)$applied > 0 ? min((int)$applied, time()) : 0,
            ];
        }
        if (trim($version) !== '') {
            $fields['version'] = mb_substr(trim($version), 0, 64);
        }
        if ($installedAt > 0) {
            $fields['installed_at'] = min($installedAt, time());
        }
        return $fields;
    }

    private function tokenHash(string $machineId): string {
        $qb = $this->db->getQueryBuilder();
        $qb->select('token_hash')->from(self::TABLE)->where($qb->expr()->eq('machine_id', $qb->createNamedParameter($machineId)));
        $result = $qb->executeQuery();
        $hash = $result->fetchOne();
        $result->closeCursor();
        return $hash === false ? '' : (string)$hash;
    }

    private function filter(IQueryBuilder $qb, string $search): void {
        $search = trim($search);
        if ($search === '') {
            return;
        }
        $like = $qb->createNamedParameter('%' . $this->db->escapeLikeParameter($search) . '%');
        $qb->where($qb->expr()->orX(
            $qb->expr()->iLike('hostname', $like),
            $qb->expr()->iLike('machine_id', $like),
            $qb->expr()->iLike('user_id', $like),
        ));
    }

    private function upsert(string $machineId, array $fields): void {
        // Look first: MySQL reports 0 affected rows for an update that changes nothing
        $find = $this->db->getQueryBuilder();
        $find->select('id')->from(self::TABLE)->where($find->expr()->eq('machine_id', $find->createNamedParameter($machineId)));
        $result = $find->executeQuery();
        $exists = $result->fetch() !== false;
        $result->closeCursor();
        if ($exists) {
            $qb = $this->db->getQueryBuilder();
            $qb->update(self::TABLE)->where($qb->expr()->eq('machine_id', $qb->createNamedParameter($machineId)));
            foreach ($fields as $column => $value) {
                $qb->set($column, $qb->createNamedParameter($value, is_int($value) ? IQueryBuilder::PARAM_INT : IQueryBuilder::PARAM_STR));
            }
            $qb->executeStatement();
            return;
        }
        $qb = $this->db->getQueryBuilder();
        $values = ['machine_id' => $qb->createNamedParameter($machineId),
            'created_at' => $qb->createNamedParameter(time(), IQueryBuilder::PARAM_INT)];
        foreach ($fields as $column => $value) {
            $values[$column] = $qb->createNamedParameter($value, is_int($value) ? IQueryBuilder::PARAM_INT : IQueryBuilder::PARAM_STR);
        }
        $qb->insert(self::TABLE)->values($values)->executeStatement();
    }

    private function machineId(string $machineId): string {
        $machineId = strtolower(trim($machineId));
        if (!preg_match('/^[0-9a-f]{32}$/', $machineId)) {
            throw new InvalidArgumentException('Invalid machine id');
        }
        return $machineId;
    }

    private function hostname(string $hostname): string {
        return mb_substr(trim($hostname), 0, 255);
    }

    private function format(array $row): array {
        return [
            'machine_id' => $row['machine_id'],
            'hostname' => $row['hostname'],
            'user_id' => $row['user_id'],
            'user_seen_at' => (int)$row['user_seen_at'],
            'last_contact' => (int)$row['last_contact'],
            'policy' => $row['policy_name'] === '' ? null : [
                'name' => $row['policy_name'],
                'serial' => (int)$row['policy_serial'],
                'source' => $row['policy_source'],
                'applied_at' => (int)$row['policy_applied_at'],
            ],
            'version' => $row['version'],
            'installed_at' => (int)$row['installed_at'],
            'disk_uuid' => $row['disk_uuid'],
            'has_key' => (bool)(int)$row['has_key'],
            'key_user_id' => $row['key_user_id'],
            'key_updated_at' => (int)$row['key_updated_at'],
            'updated_at' => (int)$row['key_updated_at'],   // the name in app 0.4.0's recovery-keys API
            'created_at' => (int)$row['created_at'],
            'has_admin_password' => (bool)(int)($row['has_admin_password'] ?? 0),
            'admin_user' => $row['admin_user'] ?? '',
            'admin_password_at' => (int)($row['admin_password_at'] ?? 0),
            // shown, and the computer hasn't reported a new one yet
            'admin_password_rotating' => (int)($row['admin_password_at'] ?? 0) > 0
                && (int)($row['admin_password_shown_at'] ?? 0) >= (int)($row['admin_password_at'] ?? 0),
            'enrolled' => (int)($row['enroll_token_id'] ?? 0) > 0,
        ];
    }
}
