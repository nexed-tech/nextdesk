<?php

declare(strict_types=1);

namespace OCA\NextDesk\Migration;

use Closure;
use OCP\DB\ISchemaWrapper;
use OCP\DB\Types;
use OCP\Migration\IOutput;
use OCP\Migration\SimpleMigrationStep;

/** Disk recovery keys of NextDesk devices (one per machine id). */
class Version000200Date20261008000000 extends SimpleMigrationStep {
    public function changeSchema(IOutput $output, Closure $schemaClosure, array $options): ?ISchemaWrapper {
        /** @var ISchemaWrapper $schema */
        $schema = $schemaClosure();
        if ($schema->hasTable('nextdesk_recovery_keys')) {
            return null;
        }
        $table = $schema->createTable('nextdesk_recovery_keys');
        $table->addColumn('id', Types::BIGINT, ['autoincrement' => true, 'notnull' => true, 'unsigned' => true]);
        $table->addColumn('machine_id', Types::STRING, ['notnull' => true, 'length' => 64]);
        $table->addColumn('hostname', Types::STRING, ['notnull' => true, 'length' => 255, 'default' => '']);
        $table->addColumn('disk_uuid', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
        $table->addColumn('user_id', Types::STRING, ['notnull' => true, 'length' => 64]);
        $table->addColumn('recovery_key', Types::TEXT, ['notnull' => true]);
        $table->addColumn('created_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true]);
        $table->addColumn('updated_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true]);
        $table->setPrimaryKey(['id']);
        $table->addUniqueIndex(['machine_id'], 'nextdesk_rk_machine');
        return $schema;
    }
}
