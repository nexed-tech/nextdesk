<?php

declare(strict_types=1);

namespace OCA\NextDesk\Migration;

use Closure;
use OCP\DB\ISchemaWrapper;
use OCP\DB\Types;
use OCP\Migration\IOutput;
use OCP\Migration\SimpleMigrationStep;

/**
 * Enrollment tokens (a computer registers itself during install) and each computer's local admin
 * password (random per computer, escrowed like the recovery key).
 */
class Version000700Date20261013000000 extends SimpleMigrationStep {
    public function changeSchema(IOutput $output, Closure $schemaClosure, array $options): ?ISchemaWrapper {
        /** @var ISchemaWrapper $schema */
        $schema = $schemaClosure();
        $changed = false;
        if (!$schema->hasTable('nextdesk_enroll_tokens')) {
            $table = $schema->createTable('nextdesk_enroll_tokens');
            $table->addColumn('id', Types::BIGINT, ['autoincrement' => true, 'notnull' => true, 'unsigned' => true]);
            // sha256 of the token: the token itself is shown once, at creation
            $table->addColumn('token_hash', Types::STRING, ['notnull' => true, 'length' => 64]);
            $table->addColumn('created_by', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
            $table->addColumn('created_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true]);
            $table->addColumn('expires_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true]);
            $table->addColumn('revoked_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
            // How many computers enrolled with it (no limit; an unexpected number stands out)
            $table->addColumn('enrolled', Types::INTEGER, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
            $table->setPrimaryKey(['id']);
            $table->addUniqueIndex(['token_hash'], 'nextdesk_enroll_hash');
            $changed = true;
        }
        $computers = $schema->getTable('nextdesk_computers');
        if (!$computers->hasColumn('admin_password')) {
            $computers->addColumn('admin_user', Types::STRING, ['notnull' => true, 'length' => 64, 'default' => '']);
            // Encrypted with the instance secret (ICrypto), like the recovery key
            $computers->addColumn('admin_password', Types::TEXT, ['notnull' => false]);
            $computers->addColumn('admin_password_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
            // Shown on the computers page after it was set: the machine sets a new one
            $computers->addColumn('admin_password_shown_at', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
            // The enrollment token it registered with (0: registered at a sign-in)
            $computers->addColumn('enroll_token_id', Types::BIGINT, ['notnull' => true, 'unsigned' => true, 'default' => 0]);
            $changed = true;
        }
        return $changed ? $schema : null;
    }
}
