Chai Protocol
=================

The Chai Protocol is an Ethereum smart contract for supplying or borrowing assets. Through the chToken contracts, accounts on the blockchain *supply* capital (Ether or ERC-20 tokens) to receive chTokens or *borrow* assets from the protocol (holding other assets as collateral). The Chai chToken contracts track these balances and algorithmically set interest rates for borrowers.

Contracts
=========

We detail a few of the core contracts in the Chai protocol.

<dl>
  <dt>ChToken, ChErc20 and ChEther</dt>
  <dd>The Chai chTokens, which are self-contained borrowing and lending contracts. ChToken contains the core logic and ChErc20 and ChEther add public interfaces for Erc20 tokens and ether, respectively. Each ChToken is assigned an interest rate and risk model (see InterestRateModel and Comptroller sections), and allows accounts to *mint* (supply capital), *redeem* (withdraw capital), *borrow* and *repay a borrow*. Each ChToken is an ERC-20 compliant token where balances represent ownership of the market.</dd>
</dl>

<dl>
  <dt>Comptroller</dt>
  <dd>The risk model contract, which validates permissible user actions and disallows actions if they do not fit certain risk parameters. For instance, the Comptroller enforces that each borrowing user must maintain a sufficient collateral balance across all chTokens.</dd>
</dl>


<dl>
  <dt>InterestRateModel</dt>
  <dd>Contracts which define interest rate models. These models algorithmically determine interest rates based on the current utilization of a given market (that is, how much of the supplied assets are liquid versus borrowed).</dd>
</dl>

<dl>
  <dt>Careful Math</dt>
  <dd>Library for safe math operations.</dd>
</dl>

<dl>
  <dt>ErrorReporter</dt>
  <dd>Library for tracking error codes and failure conditions.</dd>
</dl>

<dl>
  <dt>Exponential</dt>
  <dd>Library for handling fixed-point decimal numbers.</dd>
</dl>

<dl>
  <dt>SafeToken</dt>
  <dd>Library for safely handling Erc20 interaction.</dd>
</dl>