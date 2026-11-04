// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MovieTime — onchain catalog, subscriptions and payments for BOT Chain.
/// Video files are NOT stored onchain: only metadata and an external URL reference.
/// Kinds: 1 Movie, 2 Series, 3 Season, 4 Episode, 5 Documentary, 6 Short, 7 Trailer.
/// parentId: 0 = none; Season -> Series id; Episode -> Season id.
contract MovieTime {
    struct Title {
        uint8 kind; uint256 parentId; uint16 number; uint16 year; uint16 runtime;
        uint8 rating; // rating x10 (e.g. 78 = 7.8)
        uint256 categoryId; bool premium; bool published; bool featured;
        string title; string description; string poster; string banner; string genre; string cast;
    }
    struct Plan { uint64 duration; uint256 priceBot; uint256 priceUsdt; bool active; }
    struct Payment { address user; uint8 planId; bool usdt; uint256 amount; uint64 start; uint64 expiry; uint64 paidAt; }
    struct Profile { string name; string avatar; }
    struct Category { string name; bool active; }

    address public owner;
    address public treasury;
    address public usdt;
    mapping(address => bool) public isAdmin;

    Title[] private _titles;                       // index 0 is a dummy so ids start at 1
    mapping(uint256 => string) private _video;     // "720p|url;1080p|url" or a plain URL
    mapping(uint256 => string) private _subtitle;  // "en|https://.../file.vtt"
    Category[] private _cats;
    Plan[4] public plans;                          // 0 weekly, 1 monthly, 2 quarterly, 3 yearly
    mapping(address => uint64) public expiryOf;
    mapping(address => Profile) public profiles;
    Payment[] private _pay;
    mapping(address => uint256[]) private _userPay;
    uint256 public subscriberCount;
    uint256 public botRevenue;
    uint256 public usdtRevenue;
    bool private _lock;

    event TitleSaved(uint256 indexed id);
    event Subscribed(address indexed user, uint8 planId, bool usdt, uint256 amount, uint64 expiry);
    event PlanSet(uint8 indexed planId);

    modifier onlyOwner() { require(msg.sender == owner, "Owner only"); _; }
    modifier onlyAdmin() { require(isAdmin[msg.sender], "Admin only"); _; }
    modifier nonReentrant() { require(!_lock, "Reentrancy"); _lock = true; _; _lock = false; }

    constructor(address _treasury, address _usdt) {
        require(_treasury != address(0), "Treasury");
        owner = msg.sender; isAdmin[msg.sender] = true;
        treasury = _treasury; usdt = _usdt;
        _titles.push();
        plans[0].duration = 7 days; plans[1].duration = 30 days;
        plans[2].duration = 90 days; plans[3].duration = 365 days;
        _cats.push(Category("General", true));
    }

    // ---------- Admin ----------
    function addAdmin(address a) external onlyOwner { isAdmin[a] = true; }
    function removeAdmin(address a) external onlyOwner { require(a != owner, "Owner"); isAdmin[a] = false; }
    function transferOwnership(address a) external onlyOwner { require(a != address(0)); owner = a; isAdmin[a] = true; }
    function setTreasury(address a) external onlyOwner { require(a != address(0)); treasury = a; }
    function setUsdt(address a) external onlyOwner { usdt = a; }

    function setPlan(uint8 id, uint64 duration, uint256 priceBot, uint256 priceUsdt, bool active) external onlyAdmin {
        require(id < 4 && duration > 0, "Plan");
        plans[id] = Plan(duration, priceBot, priceUsdt, active);
        emit PlanSet(id);
    }

    function addCategory(string calldata name) external onlyAdmin { _cats.push(Category(name, true)); }
    function setCategory(uint256 id, string calldata name, bool active) external onlyAdmin {
        require(id < _cats.length, "Category"); _cats[id] = Category(name, active);
    }

    function addTitle(Title calldata t, string calldata video, string calldata subtitle) external onlyAdmin returns (uint256 id) {
        _check(t);
        id = _titles.length;
        _titles.push(t); _video[id] = video; _subtitle[id] = subtitle;
        emit TitleSaved(id);
    }
    function editTitle(uint256 id, Title calldata t, string calldata video, string calldata subtitle) external onlyAdmin {
        require(id > 0 && id < _titles.length, "Title"); _check(t);
        _titles[id] = t; _video[id] = video; _subtitle[id] = subtitle;
        emit TitleSaved(id);
    }
    function setPublished(uint256 id, bool v) external onlyAdmin { require(id > 0 && id < _titles.length); _titles[id].published = v; emit TitleSaved(id); }
    function setFeatured(uint256 id, bool v) external onlyAdmin { require(id > 0 && id < _titles.length); _titles[id].featured = v; emit TitleSaved(id); }
    function _check(Title calldata t) private view {
        require(t.kind >= 1 && t.kind <= 7 && t.categoryId < _cats.length && t.parentId < _titles.length, "Invalid title");
    }

    // ---------- Catalog reads ----------
    function nextId() external view returns (uint256) { return _titles.length; }
    function getTitle(uint256 id) external view returns (Title memory) { require(id > 0 && id < _titles.length, "Title"); return _titles[id]; }
    function getTitles(uint256 from, uint256 count) external view returns (Title[] memory out) {
        uint256 end = from + count; if (end > _titles.length) end = _titles.length;
        if (from >= end) return out;
        out = new Title[](end - from);
        for (uint256 i = from; i < end; i++) out[i - from] = _titles[i];
    }
    function getCategories() external view returns (string[] memory names, bool[] memory active) {
        names = new string[](_cats.length); active = new bool[](_cats.length);
        for (uint256 i = 0; i < _cats.length; i++) { names[i] = _cats[i].name; active[i] = _cats[i].active; }
    }

    /// Premium video references are returned only to active subscribers (or admins).
    /// NOTE: contract storage is publicly readable via raw RPC; this gates the app/API layer,
    /// not a determined reader. Use expiring signed URLs at your video host for hard protection.
    function getVideo(uint256 id) external view returns (string memory video, string memory subtitle) {
        require(id > 0 && id < _titles.length, "Title");
        Title storage t = _titles[id];
        require(t.published || isAdmin[msg.sender], "Unpublished");
        require(!t.premium || isActive(msg.sender) || isAdmin[msg.sender], "Subscription required");
        return (_video[id], _subtitle[id]);
    }

    // ---------- Profile ----------
    function setProfile(string calldata name, string calldata avatar) external { profiles[msg.sender] = Profile(name, avatar); }

    // ---------- Subscriptions ----------
    function isActive(address u) public view returns (bool) { return expiryOf[u] > block.timestamp; }

    /// Explicit, user-signed purchase. No recurring pull: renewal is another call by the user.
    function subscribe(uint8 planId, bool useUsdt) external payable nonReentrant {
        require(planId < 4, "Plan");
        Plan memory p = plans[planId];
        require(p.active, "Plan inactive");
        uint256 price = useUsdt ? p.priceUsdt : p.priceBot;
        require(price > 0, "Currency unavailable");

        uint64 start = expiryOf[msg.sender] > block.timestamp ? expiryOf[msg.sender] : uint64(block.timestamp);
        uint64 exp = start + p.duration;
        if (_userPay[msg.sender].length == 0) subscriberCount++;
        expiryOf[msg.sender] = exp;
        _userPay[msg.sender].push(_pay.length);
        _pay.push(Payment(msg.sender, planId, useUsdt, price, start, exp, uint64(block.timestamp)));

        if (useUsdt) {
            require(msg.value == 0 && usdt != address(0), "USDT");
            usdtRevenue += price;
            (bool ok, bytes memory r) = usdt.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, treasury, price));
            require(ok && (r.length == 0 || abi.decode(r, (bool))), "USDT transfer failed");
        } else {
            require(msg.value == price, "Exact BOT required");
            botRevenue += price;
            (bool sent, ) = treasury.call{value: price}("");
            require(sent, "Treasury transfer failed");
        }
        emit Subscribed(msg.sender, planId, useUsdt, price, exp);
    }

    // ---------- Payment reads ----------
    function paymentCount() external view returns (uint256) { return _pay.length; }
    function getPayments(address u) external view returns (Payment[] memory out) {
        uint256[] storage ids = _userPay[u]; out = new Payment[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) out[i] = _pay[ids[i]];
    }
    function getPaymentRange(uint256 from, uint256 count) external view onlyAdmin returns (Payment[] memory out) {
        uint256 end = from + count; if (end > _pay.length) end = _pay.length;
        if (from >= end) return out;
        out = new Payment[](end - from);
        for (uint256 i = from; i < end; i++) out[i - from] = _pay[i];
    }
}
