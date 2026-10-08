<?php

declare(strict_types=1);

namespace OCA\NextDesk\Service;

use InvalidArgumentException;
use OCP\DB\QueryBuilder\IQueryBuilder;
use OCP\IDBConnection;
use OCP\Security\ICrypto;
use Psr\Log\LoggerInterface;

/**
 * Disk recovery keys of NextDesk devices: escrow, like BitLocker keys in Intune.
 *
 * A device uploads its key (the installer's, or a new one from `nextdesk-recovery-key --new`)
 * with a signed-in user's app password; one entry per machine id, a new key replaces the old.
 * Stored encrypted with the instance secret (ICrypto). Only administrators can read them, and
 * every read is logged.
 */
class RecoveryKeyService {
    private const TABLE = 'nextdesk_recovery_keys';
    // systemd-cryptenroll recovery keys: 8 groups of 8 modhex characters
    private const KEY_RE = '/^([cbdefghijklnrtuv]{8}-){7}[cbdefghijklnrtuv]{8}$/';

    public function __construct(
        private IDBConnection $db,
        private ICrypto $crypto,
        private LoggerInterface $logger,
    ) {
    }

    public function store(string $machineId, string $hostname, string $diskUuid, string $userId, string $key): void {
        $machineId = strtolower(trim($machineId));
        $key = strtolower(trim($key));
        if (!preg_match('/^[0-9a-f]{32}$/', $machineId)) {
            throw new InvalidArgumentException('Invalid machine id');
        }
        if (!preg_match(self::KEY_RE, $key)) {
            throw new InvalidArgumentException('Invalid recovery key');
        }
        $hostname = mb_substr(trim($hostname), 0, 255);
        $diskUuid = preg_match('/^[0-9a-fA-F-]{1,64}$/', $diskUuid) ? strtolower($diskUuid) : '';
        $now = time();
        $encrypted = $this->crypto->encrypt($key);

        $qb = $this->db->getQueryBuilder();
        $updated = $qb->update(self::TABLE)
            ->set('hostname', $qb->createNamedParameter($hostname))
            ->set('disk_uuid', $qb->createNamedParameter($diskUuid))
            ->set('user_id', $qb->createNamedParameter($userId))
            ->set('recovery_key', $qb->createNamedParameter($encrypted))
            ->set('updated_at', $qb->createNamedParameter($now, IQueryBuilder::PARAM_INT))
            ->where($qb->expr()->eq('machine_id', $qb->createNamedParameter($machineId)))
            ->executeStatement();
        if ($updated === 0) {
            $qb = $this->db->getQueryBuilder();
            $qb->insert(self::TABLE)->values([
                'machine_id' => $qb->createNamedParameter($machineId),
                'hostname' => $qb->createNamedParameter($hostname),
                'disk_uuid' => $qb->createNamedParameter($diskUuid),
                'user_id' => $qb->createNamedParameter($userId),
                'recovery_key' => $qb->createNamedParameter($encrypted),
                'created_at' => $qb->createNamedParameter($now, IQueryBuilder::PARAM_INT),
                'updated_at' => $qb->createNamedParameter($now, IQueryBuilder::PARAM_INT),
            ])->executeStatement();
        }
        $this->logger->info("NextDesk: recovery key of $hostname ($machineId) stored, sent by $userId", ['app' => 'nextdesk']);
    }

    /** All devices, without their keys. */
    public function list(): array {
        $qb = $this->db->getQueryBuilder();
        $result = $qb->select('machine_id', 'hostname', 'disk_uuid', 'user_id', 'created_at', 'updated_at')
            ->from(self::TABLE)
            ->orderBy('hostname')
            ->executeQuery();
        $rows = [];
        while ($row = $result->fetch()) {
            $rows[] = $this->format($row);
        }
        $result->closeCursor();
        return $rows;
    }

    /**
     * The devices matching a machine id or hostname, with their keys. Logged: who read which.
     */
    public function reveal(string $machineIdOrHostname, string $by): array {
        $qb = $this->db->getQueryBuilder();
        $result = $qb->select('*')
            ->from(self::TABLE)
            ->where($qb->expr()->orX(
                $qb->expr()->eq('machine_id', $qb->createNamedParameter(strtolower($machineIdOrHostname))),
                $qb->expr()->eq('hostname', $qb->createNamedParameter($machineIdOrHostname)),
            ))
            ->executeQuery();
        $rows = [];
        while ($row = $result->fetch()) {
            $device = $this->format($row);
            $device['recovery_key'] = $this->crypto->decrypt($row['recovery_key']);
            $rows[] = $device;
            $this->logger->warning("NextDesk: recovery key of {$row['hostname']} ({$row['machine_id']}) shown to $by",
                ['app' => 'nextdesk']);
        }
        $result->closeCursor();
        return $rows;
    }

    public function delete(string $machineId): bool {
        $qb = $this->db->getQueryBuilder();
        return $qb->delete(self::TABLE)
            ->where($qb->expr()->eq('machine_id', $qb->createNamedParameter(strtolower($machineId))))
            ->executeStatement() > 0;
    }

    private function format(array $row): array {
        return [
            'machine_id' => $row['machine_id'],
            'hostname' => $row['hostname'],
            'disk_uuid' => $row['disk_uuid'],
            'user_id' => $row['user_id'],
            'created_at' => (int)$row['created_at'],
            'updated_at' => (int)$row['updated_at'],
        ];
    }
}
