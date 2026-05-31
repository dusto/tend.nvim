local configDefault = require("tend.config_default")

--- @type tend.UserConfig
local Config = vim.tbl_deep_extend("force", configDefault, {})

return Config
