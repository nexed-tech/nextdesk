<?php

declare(strict_types=1);

namespace OCA\NextDesk\Command;

use OCA\NextDesk\Service\ComputerService;
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
        private ComputerService $computers,
    ) {
        parent::__construct();
    }

    protected function configure(): void {
        $this->setName('nextdesk:recovery-key')
            ->setDescription('List NextDesk devices with an escrowed disk recovery key, or show one')
            ->addArgument('device', InputArgument::OPTIONAL, 'Hostname or machine id')
            ->addOption('delete', null, InputOption::VALUE_NONE, 'Delete this computer (machine id) and its key');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {
        $device = $input->getArgument('device');
        if ($device === null) {
            foreach ($this->computers->withKeys() as $d) {
                $output->writeln(sprintf('%-24s %s  %s  %s', $d['hostname'], $d['machine_id'], $d['user_id'],
                    date('Y-m-d H:i', $d['updated_at'])));
            }
            return 0;
        }
        if ($input->getOption('delete')) {
            if (!$this->computers->delete($device, 'occ')) {
                $output->writeln("<error>No recovery key for machine id $device</error>");
                return 1;
            }
            $output->writeln('Deleted.');
            return 0;
        }
        $devices = $this->computers->revealKey($device, 'occ');
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
