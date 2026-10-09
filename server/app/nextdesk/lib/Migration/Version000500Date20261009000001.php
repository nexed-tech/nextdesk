<?php

declare(strict_types=1);

namespace OCA\NextDesk\Migration;

use Closure;
use OCP\DB\ISchemaWrapper;
use OCP\Migration\IOutput;
use OCP\Migration\SimpleMigrationStep;

/** The recovery keys live in nextdesk_computers now (copied by the previous step). */
class Version000500Date20261009000001 extends SimpleMigrationStep {
    public function changeSchema(IOutput $output, Closure $schemaClosure, array $options): ?ISchemaWrapper {
        /** @var ISchemaWrapper $schema */
        $schema = $schemaClosure();
        if (!$schema->hasTable('nextdesk_recovery_keys') || !$schema->hasTable('nextdesk_computers')) {
            return null;
        }
        $schema->dropTable('nextdesk_recovery_keys');
        return $schema;
    }
}
