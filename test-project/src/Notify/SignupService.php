<?php

declare(strict_types=1);

namespace Test\Notify;

/**
 * Depends on the NotifierInterface abstraction (never the concrete class).
 * Without DI-aware resolution the call below is unresolved; with single-
 * implementor binding it resolves to EmailNotifier::send.
 */
class SignupService
{
    public function __construct(
        private readonly NotifierInterface $notifier,
    ) {}

    public function register(string $email): void
    {
        $this->notifier->send('Welcome ' . $email);
    }
}
