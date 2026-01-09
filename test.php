<?php

namespace App\Services;

class UserService {
    private $repository;

    public function __construct(UserRepository $repository) {
        $this->repository = $repository;
    }

    public function findUser(int $id): ?User {
        return $this->repository->findById($id);
    }

    public function createUser(array $data): User {
        $user = new User();
        $user->setName($data['name']);
        $user->setEmail($data['email']);

        $this->validate($user);
        $this->repository->save($user);

        $this->sendWelcomeEmail($user);

        return $user;
    }

    private function validate(User $user): void {
        if (empty($user->getName())) {
            throw new \InvalidArgumentException('Name is required');
        }
    }

    private function sendWelcomeEmail(User $user): void {
        $mailer = new Mailer();
        $mailer->send($user->getEmail(), 'Welcome!', 'Hello ' . $user->getName());
    }
}

class UserRepository {
    public function findById(int $id): ?User {
        return User::find($id);
    }

    public function save(User $user): void {
        $user->save();
    }
}

function helper_function(string $value): string {
    return trim($value);
}

function process_users(array $users): void {
    foreach ($users as $user) {
        $name = helper_function($user['name']);
        echo $name;
    }
}
