<?php

declare(strict_types=1);

namespace Pickware\Phpcma;

use Composer\Composer;
use Composer\EventDispatcher\EventSubscriberInterface;
use Composer\Installer\PackageEvent;
use Composer\Installer\PackageEvents;
use Composer\IO\IOInterface;
use Composer\Plugin\PluginInterface;
use Composer\Script\Event;
use Composer\Script\ScriptEvents;

class PhpcmaPlugin implements PluginInterface, EventSubscriberInterface
{
    private Composer $composer;
    private IOInterface $io;

    public function activate(Composer $composer, IOInterface $io): void
    {
        $this->composer = $composer;
        $this->io = $io;
    }

    public function deactivate(Composer $composer, IOInterface $io): void
    {
    }

    public function uninstall(Composer $composer, IOInterface $io): void
    {
        $vendorBinDir = $composer->getConfig()->get('bin-dir');
        $binaryPath = $vendorBinDir . DIRECTORY_SEPARATOR . 'phpcma';

        if (PHP_OS_FAMILY === 'Windows') {
            $binaryPath .= '.exe';
        }

        if (file_exists($binaryPath)) {
            unlink($binaryPath);
            $io->write('<info>phpcma:</info> Binary removed');
        }
    }

    public static function getSubscribedEvents(): array
    {
        return [
            ScriptEvents::POST_INSTALL_CMD => 'onPostInstallOrUpdate',
            ScriptEvents::POST_UPDATE_CMD => 'onPostInstallOrUpdate',
        ];
    }

    public function onPostInstallOrUpdate(Event $event): void
    {
        $version = $this->getVersion();
        $vendorBinDir = $this->composer->getConfig()->get('bin-dir');

        $installer = new BinaryInstaller($version, $this->io);
        $installer->install($vendorBinDir);
    }

    private function getVersion(): string
    {
        $packages = $this->composer->getRepositoryManager()
            ->getLocalRepository()
            ->getPackages();

        foreach ($packages as $package) {
            if ($package->getName() === 'pickware/phpcma') {
                $version = $package->getPrettyVersion();
                // Ensure the version has a 'v' prefix for GitHub release tags
                if (!str_starts_with($version, 'v')) {
                    $version = 'v' . $version;
                }
                return $version;
            }
        }

        // Fallback: read from own composer.json
        $extra = $this->composer->getPackage()->getExtra();
        if (isset($extra['phpcma']['version'])) {
            return (string) $extra['phpcma']['version'];
        }

        throw new \RuntimeException(
            'Could not determine phpcma version. Ensure pickware/phpcma is properly installed.',
        );
    }

    /**
     * Provides the "phpcma:check" script command
     */
    public static function checkTypes(Event $event): void
    {
        $vendorBinDir = $event->getComposer()->getConfig()->get('bin-dir');
        $binary = $vendorBinDir . DIRECTORY_SEPARATOR . 'phpcma';

        if (PHP_OS_FAMILY === 'Windows') {
            $binary .= '.exe';
        }

        if (!file_exists($binary)) {
            $event->getIO()->writeError('<error>phpcma binary not found. Run composer install first.</error>');
            return;
        }

        $composerJsonPath = getcwd() . DIRECTORY_SEPARATOR . 'composer.json';
        $args = ['check-types', '-c', 'composer.json'];

        $config = BinaryInstaller::readConfig($composerJsonPath);
        if (!empty($config['strict'])) {
            $args[] = '--strict';
        }
        if (isset($config['min-confidence'])) {
            $args[] = '--min-confidence=' . $config['min-confidence'];
        }
        if (!empty($config['checks'])) {
            foreach ($config['checks'] as $check) {
                $args[] = '--check=' . $check;
            }
        }
        if (!empty($config['called-before'])) {
            foreach ($config['called-before'] as $calledBefore) {
                $args[] = '--called-before=' . $calledBefore;
            }
        }

        $command = escapeshellarg($binary) . ' ' . implode(' ', array_map('escapeshellarg', $args));
        passthru($command, $exitCode);

        if ($exitCode !== 0) {
            throw new \RuntimeException('phpcma check-types failed with exit code ' . $exitCode);
        }
    }
}
