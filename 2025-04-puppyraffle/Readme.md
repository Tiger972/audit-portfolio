puppy-raffle

Puppy Raffle
This project is to enter a raffle to win a cute dog NFT. The protocol should do the following:

Call the enterRaffle function with the following parameters:
address[] participants: A list of addresses that enter. You can use this to enter yourself multiple times, or yourself and a group of your friends.
Duplicate addresses are not allowed
Users are allowed to get a refund of their ticket & value if they call the refund function
Every X seconds, the raffle will be able to draw a winner and be minted a random puppy
The owner of the protocol will set a feeAddress to take a cut of the value, and the rest of the funds will be sent to the winner of the puppy.
Puppy Raffle
Getting Started
Requirements
Quickstart
Optional Gitpod
Usage
Testing
Test Coverage
Audit Scope Details
Compatibilities
Roles
Known Issues
Getting Started
Requirements
git
You'll know you did it right if you can run git --version and you see a response like git version x.x.x
foundry
You'll know you did it right if you can run forge --version and you see a response like forge 0.2.0 (816e00b 2023-03-16T00:05:26.396218Z)
Quickstart
git clone https://github.com/Cyfrin/4-puppy-raffle-audit
cd 4-puppy-raffle-audit
make
Optional Gitpod
If you can't or don't want to run and install locally, you can work with this repo in Gitpod. If you do this, you can skip the clone this repo part.

Open in Gitpod

Usage
Testing
forge test
Test Coverage
forge coverage
and for coverage based testing:

forge coverage --report debug
Audit Scope Details
Commit Hash: 2a47715b30cf11ca82db148704e67652ad679cd8
In Scope:
./src/
└── PuppyRaffle.sol
Compatibilities
Solc Version: 0.7.6
Chain(s) to deploy contract to: Ethereum
Roles
Owner - Deployer of the protocol, has the power to change the wallet address to which fees are sent through the changeFeeAddress function. Player - Participant of the raffle, has the power to enter the raffle with the enterRaffle function and refund value through refund function.

Known Issues
None
