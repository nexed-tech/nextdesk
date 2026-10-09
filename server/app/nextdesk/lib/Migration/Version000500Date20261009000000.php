<?php

declare(strict_types=1);

namespace OCA\NextDesk\Migration;

use Closure;
use OCP\DB\ISchemaWrapper;
use OCP\DB\QueryBuilder\IQueryBuilder;
use OCP\DB\Types;
use OCP\IDBConnection;
use OCP\Migration\IOutput;
use OCP\Migration\SimpleMigrationStep;

/**
 * NextDesk computers (one per machine id): what they report when they check in, and their disk
 * recovery key. Takes over the rows of nextdesk_recovery_keys (dropped by the next step).
 */
class Version000500Date20261009000000 extends SimpleMigrationStep {
    public function __construct(
        private IDBConnection $db,
    ) {
    }

    public function changeSchema(IOutput $output, Closure $schemaClosure, array $options): ?ISchemaWrapper {
        /** @var ISchemaWrapper $schema */
        $schema = $schemaClosure();
        if ($schema->hasTable('nextdesk_computers')) {
            return null;
        }
        $table = $schema->createTable('nextdesk_computers');
        $table->addColumn('id', Types::BIGINT, ['autoincrement' => true, 'notnull' => true, 'unsigned' => true]);
        $table->addColumn('machine_id', Types::STRING, ['notnull' => true, 'length' => 64]);
        $table->addColumn('hostname', Types::STRING, ['notnull' => true, 'length' => 255, 'default' => '']);
        // Last signed-in user that reported (app password check-in) and when
        $table->addColumn('user_id', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
        $table->addColumn('user_seen_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
        // Any report: also the machine's own (device token), with nobody signed in
        $table->addColumn('last_contact', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
        $table->addColumn('policy_name', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
        $table->addColumn('policy_serial', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
        $table->addColumn('policy_source', Types::STRING, ['notnull' => true, 'length' => 1024, 'default' => '']);
        $table->addColumn('policy_applied_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
        $table->addColumn('version', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
        // When NextDesk OS was installed on it (reported by the machine)
        $table->addColumn('installed_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
        // sha256 of the machine's device token (handed out at a check-in with an app password)
        $table->addColumn('token_hash', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
        $table->addColumn('disk_uuid', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
        $table->addColumn('recovery_key', Types::TEXT, ['notnull' => false]);
        $table->addColumn('key_user_id', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
        $table->addColumn('key_updated_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
        $table->addColumn('created_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true]);
        $table->setPrimaryKey(['id']);
        $table->addUniqueIndex(['machine_id'], 'nextdesk_comp_machine');
        $table->addIndex(['last_contact'], 'nextdesk_comp_contact');
        return $schema;
    }

    public function postSchemaChange(IOutput $output, Closure $schemaClosure, array $options): void {
        /** @var ISchemaWrapper $schema */
        $schema = $schemaClosure();
        if (!$schema->hasTable('nextdesk_recovery_keys')) {
            return;
        }
        $result = $this->db->getQueryBuilder()->select('*')->from('nextdesk_recovery_keys')->executeQuery();
        $copied = 0;
        while ($row = $result->fetch()) {
            $exists = $this->db->getQueryBuilder();
            $exists->select('id')->from('nextdesk_computers')
                ->where($exists->expr()->eq('machine_id', $exists->createNamedParameter($row['machine_id'])));
            $found = $exists->executeQuery();
            $already = $found->fetch() !== false;
            $found->closeCursor();
            if ($already) {
                continue;
            }
            $qb = $this->db->getQueryBuilder();
            $qb->insert('nextdesk_computers')->values([
                'machine_id' => $qb->createNamedParameter($row['machine_id']),
                'hostname' => $qb->createNamedParameter($row['hostname']),
                'user_id' => $qb->createNamedParameter($row['user_id']),
                'user_seen_at' => $qb->createNamedParameter((int)$row['updated_at'], IQueryBuilder::PARAM_INT),
                'last_contact' => $qb->createNamedParameter((int)$row['updated_at'], IQueryBuilder::PARAM_INT),
                'disk_uuid' => $qb->createNamedParameter($row['disk_uuid']),
                'recovery_key' => $qb->createNamedParameter($row['recovery_key']),
                'key_user_id' => $qb->createNamedParameter($row['user_id']),
                'key_updated_at' => $qb->createNamedParameter((int)$row['updated_at'], IQueryBuilder::PARAM_INT),
                'created_at' => $qb->createNamedParameter((int)$row['created_at'], IQueryBuilder::PARAM_INT),
            ])->executeStatement();
            $copied++;
        }
        $result->closeCursor();
        $output->info("NextDesk: $copied recovery key(s) moved to the computers table");
    }
}
