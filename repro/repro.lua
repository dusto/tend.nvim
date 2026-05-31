vim.env.LAZY_STDPATH = "../lazy_repro"

load(
    vim.fn.system(
        "curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua"
    )
)()

require("lazy.minit").repro({
    spec = {
        {
            name = "tend.nvim",
            dir = vim.fn.fnamemodify(vim.uv.cwd() or "", ":h"),

            opts = {},

            keys = {
                {
                    "<C-\\>",
                    function()
                        require("tend").toggle()
                    end,
                    desc = "Tend Open",
                    silent = true,
                    mode = { "n", "v", "i" },
                },

                {
                    "<C-'>",
                    function()
                        require("tend").add_selection_or_file_to_context()
                    end,
                    desc = "Tend Add Selection to context",
                    silent = true,
                    mode = { "n", "v" },
                },

                {
                    "<C-,>",
                    function()
                        require("tend").new_session()
                    end,
                    desc = "Tend New Session",
                    silent = true,
                    mode = { "n", "v", "i" },
                },
            },
        },
    },
})
