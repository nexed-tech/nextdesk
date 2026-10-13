<?php

declare(strict_types=1);

namespace OCA\NextDesk\Service;

use OCP\DB\QueryBuilder\IQueryBuilder;
use OCP\IDBConnection;
use OCP\Security\ISecureRandom;
use Psr\Log\LoggerInterface;

/**
 * Enrollment tokens: an administrator creates one (valid 24 hours, revocable) and puts it on the
 * installer's USB stick (nextdesk-install.json) or types it in the installer. A computer installed
 * with it registers itself at its first start: it's on the computers page right away, and its
 * recovery key and local admin password are escrowed before anyone signs in.
 *
 * A token can only register computers and store their own secrets; it reads nothing. Someone who
 * finds one can install a NextDesk computer, which still needs a Nextcloud account to sign in.
 */
class EnrollmentService {
    private const TABLE = 'nextdesk_enroll_tokens';
    public const VALID_FOR = 86400;

    public function __construct(
        private IDBConnection $db,
        private ISecureRandom $random,
        private LoggerInterface $logger,
    ) {
    }

    /** @return array{id: int, token: string, created_at: int, expires_at: int} The token is only returned here. */
    public function create(string $by): array {
        $token = $this->random->generate(32, ISecureRandom::CHAR_ALPHANUMERIC);
        $now = time();
        $qb = $this->db->getQueryBuilder();
        $qb->insert(self::TABLE)->values([
            'token_hash' => $qb->createNamedParameter(hash('sha256', $token)),
            'created_by' => $qb->createNamedParameter($by),
            'created_at' => $qb->createNamedParameter($now, IQueryBuilder::PARAM_INT),
            'expires_at' => $qb->createNamedParameter($now + self::VALID_FOR, IQueryBuilder::PARAM_INT),
        ])->executeStatement();
        $id = $qb->getLastInsertId();
        $this->logger->info("NextDesk: enrollment token $id created by $by", ['app' => 'nextdesk']);
        return ['id' => $id, 'token' => $token, 'created_at' => $now, 'expires_at' => $now + self::VALID_FOR];
    }

    /** Tokens still valid (not expired or revoked), newest first, without the tokens themselves. */
    public function active(): array {
        $qb = $this->db->getQueryBuilder();
        $result = $qb->select('id', 'created_by', 'created_at', 'expires_at', 'enrolled')->from(self::TABLE)
            ->where($qb->expr()->gt('expires_at', $qb->createNamedParameter(time(), IQueryBuilder::PARAM_INT)))
            ->andWhere($qb->expr()->eq('revoked_at', $qb->createNamedParameter(0, IQueryBuilder::PARAM_INT)))
            ->orderBy('created_at', 'DESC')->executeQuery();
        $tokens = [];
        while ($row = $result->fetch()) {
            $tokens[] = ['id' => (int)$row['id'], 'created_by' => $row['created_by'],
                'created_at' => (int)$row['created_at'], 'expires_at' => (int)$row['expires_at'],
                'enrolled' => (int)$row['enrolled']];
        }
        $result->closeCursor();
        return $tokens;
    }

    public function revoke(int $id, string $by): bool {
        $qb = $this->db->getQueryBuilder();
        $done = $qb->update(self::TABLE)
            ->set('revoked_at', $qb->createNamedParameter(time(), IQueryBuilder::PARAM_INT))
            ->where($qb->expr()->eq('id', $qb->createNamedParameter($id, IQueryBuilder::PARAM_INT)))
            ->andWhere($qb->expr()->eq('revoked_at', $qb->createNamedParameter(0, IQueryBuilder::PARAM_INT)))
            ->executeStatement() > 0;
        if ($done) {
            $this->logger->warning("NextDesk: enrollment token $id revoked by $by", ['app' => 'nextdesk']);
        }
        return $done;
    }

    /** The id of a valid token, or null (unknown, expired or revoked). */
    public function valid(string $token): ?int {
        if (!preg_match('/^[A-Za-z0-9]{32}$/', $token)) {
            return null;
        }
        $qb = $this->db->getQueryBuilder();
        $result = $qb->select('id')->from(self::TABLE)
            ->where($qb->expr()->eq('token_hash', $qb->createNamedParameter(hash('sha256', $token))))
            ->andWhere($qb->expr()->gt('expires_at', $qb->createNamedParameter(time(), IQueryBuilder::PARAM_INT)))
            ->andWhere($qb->expr()->eq('revoked_at', $qb->createNamedParameter(0, IQueryBuilder::PARAM_INT)))
            ->executeQuery();
        $id = $result->fetchOne();
        $result->closeCursor();
        return $id === false ? null : (int)$id;
    }

    public function countEnrolled(int $id): void {
        $qb = $this->db->getQueryBuilder();
        $qb->update(self::TABLE)->set('enrolled', $qb->func()->add('enrolled', $qb->createNamedParameter(1, IQueryBuilder::PARAM_INT)))
            ->where($qb->expr()->eq('id', $qb->createNamedParameter($id, IQueryBuilder::PARAM_INT)))
            ->executeStatement();
    }
}
