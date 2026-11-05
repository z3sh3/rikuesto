# 这是一个为`neovim`定制的`http`client插件

项目名称`rikuesto`是日本语发音`request`的意思

## 支持的功能

- http文件语法解析与高亮，依赖于treesitter的`http`parser(目前nvim已经通过`romus204/tree-sitter-manager.nvim`插件安装)
- 实际请求使用`curl`，通过解析http文件，将其转换为合法的`curl`请求
- 支持http文件格式化，以便于以清晰的结构查看请求格式
- 严格按照http文件规范，参考链接为`https://http-files.org/guides/introduction`
- 支持从配置文件中读取环境变量，配置文件默认在`%LOCALAPPDATA%\nvim\rikuesto\env.json`中，文件类型为`json`，支持在插件中覆写配置文件路径
  配置文件示例为当前目录下的文件`env.json`，其中，`global`为固定配置项，用于存放全局配置，其中`env`表示默认使用的配置profile，`var`表示全局配置变量，可以被同名的配置profile覆盖
- 支持http文件中的`javascript`脚本解析和执行(这块具体做法不确定，需要进行调查使用轻量级方案，并且尽量使用已有的运行时和工具)
- 支持使用命令和快捷键将当前的http请求复制为curl请求

## 可以参考的项目

`https://github.com/rest-nvim/rest.nvim`
该项目使用luarock安装各种依赖，对于windows系统安装不够友好，仅参考该项目不借助外部依赖的原生实现

## 本项目不做的事情

非必要不引入外部模块

