<?php

declare(strict_types=1);

namespace OCA\NextDesk\Command;

use OCA\NextDesk\Service\RecoveryKeyService;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * occ nextdesk:recovery-key                     list the devices (no keys)
 * occ nextdesk:recovery-key nd-office-3         the key of a device (hostname or machine id)
 * occ nextdesk:recovery-key --delete <machine id>
 */
class RecoveryKey extends Command {
    public function __construct(
        private RecoveryKeyService $recoveryKeys,
    ) {
        parent::__construct();
    }

    protected function configure(): void {
        $this->setName('nextdesk:recovery-key')
            ->setDescription('List NextDesk devices with an escrowed disk recovery key, or show one')
            ->addArgument('device', InputArgument::OPTIONAL, 'Hostname or machine id')
            ->addOption('delete', null, InputOption::VALUE_NONE, 'Delete the key of this machine id');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {
        $device = $input->getArgument('device');
        if ($device === null) {
            foreach ($this->recoveryKeys->list() as $d) {
                $output->writeln(sprintf('%-24s %s  %s  %s', $d['hostname'], $d['machine_id'], $d['user_id'],
                    date('Y-m-d H:i', $d['updated_at'])));
            }
            return 0;
        }
        if ($input->getOption('delete')) {
            if (!$this->recoveryKeys->delete($device)) {
                $output->writeln("<error>No recovery key for machine id $device</error>");
                return 1;
            }
            $output->writeln('Deleted.');
            return 0;
        }
        $devices = $this->recoveryKeys->reveal($device, 'occ');
        if ($devices === []) {
            $output->writeln("<error>No recovery key for $device</error>");
            return 1;
        }
        foreach ($devices as $d) {
            $output->writeln(sprintf('%s (%s, %s): %s', $d['hostname'], $d['machine_id'],
                date('Y-m-d H:i', $d['updated_at']), $d['recovery_key']));
        }
        return 0;
    }
}
