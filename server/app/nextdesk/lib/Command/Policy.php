<?php

declare(strict_types=1);

namespace OCA\NextDesk\Command;

use InvalidArgumentException;
use OCA\NextDesk\Service\PolicyService;
use OCP\IUserManager;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * occ nextdesk:policy                                  show all policy
 * occ nextdesk:policy offline_grace_days 7            set the global value
 * occ nextdesk:policy --group field offline_grace_days 30
 * occ nextdesk:policy --user alice offline_grace_days 0
 * occ nextdesk:policy --user alice --delete            remove alice's override
 * occ nextdesk:policy --effective alice                what applies to alice
 */
class Policy extends Command {
    public function __construct(
        private PolicyService $policy,
        private IUserManager $userManager,
    ) {
        parent::__construct();
    }

    protected function configure(): void {
        $this->setName('nextdesk:policy')
            ->setDescription('Show or change NextDesk policy (global, per group or per user)')
            ->addArgument('key', InputArgument::OPTIONAL, 'Policy key: ' . implode(', ', array_keys(PolicyService::KEYS)))
            ->addArgument('value', InputArgument::OPTIONAL, 'New value; empty removes the key from this scope')
            ->addOption('group', 'g', InputOption::VALUE_REQUIRED, 'Group override instead of the global policy')
            ->addOption('user', 'u', InputOption::VALUE_REQUIRED, 'User override instead of the global policy')
            ->addOption('delete', null, InputOption::VALUE_NONE, 'Remove the whole group or user override')
            ->addOption('effective', null, InputOption::VALUE_REQUIRED, 'Show the policy that applies to this user');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int {
        if ($uid = $input->getOption('effective')) {
            $user = $this->userManager->get($uid);
            if ($user === null) {
                $output->writeln("<error>No such user: $uid</error>");
                return 1;
            }
            $output->writeln(json_encode($this->policy->effective($user), JSON_PRETTY_PRINT));
            return 0;
        }

        [$scope, $id] = match (true) {
            $input->getOption('group') !== null => ['group', (string)$input->getOption('group')],
            $input->getOption('user') !== null => ['user', (string)$input->getOption('user')],
            default => ['global', ''],
        };
        $current = match ($scope) {
            'global' => $this->policy->getGlobal(),
            'group' => $this->policy->getGroups()[$id] ?? [],
            'user' => $this->policy->getUsers()[$id] ?? [],
        };

        try {
            if ($input->getOption('delete')) {
                $this->policy->set($scope, $id, null);
            } elseif (($key = $input->getArgument('key')) !== null) {
                $value = $input->getArgument('value');
                if ($value === null || $value === '') {
                    unset($current[$key]);
                    $this->policy->sanitize([$key => null]);   // validates the key
                } else {
                    $current[$key] = $value;
                }
                $this->policy->set($scope, $id, $current);
            }
        } catch (InvalidArgumentException $e) {
            $output->writeln('<error>' . $e->getMessage() . '</error>');
            return 1;
        }

        $output->writeln(json_encode([
            'defaults' => $this->policy->defaults(),
            'global' => (object)$this->policy->getGlobal(),
            'groups' => (object)$this->policy->getGroups(),
            'users' => (object)$this->policy->getUsers(),
        ], JSON_PRETTY_PRINT));
        return 0;
    }
}
